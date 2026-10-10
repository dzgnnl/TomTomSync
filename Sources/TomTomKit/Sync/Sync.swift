import Foundation

/// High-level operations shared by the CLI and (later) the menu bar app.
public struct SyncLog {
    public var emit: (String) -> Void
    public init(_ emit: @escaping (String) -> Void) { self.emit = emit }
    func callAsFunction(_ s: String) { emit(s) }
}

// MARK: - Activity export

public struct ExportResult {
    public var ttbin: URL
    public var fit: URL?
    public var activity: Activity?
    public var deletedFromWatch: Bool
}

public enum Exporter {
    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("TomTom")

    /// Base filename from the activity's local start time, e.g. "2026-10-10_0712_running".
    public static func baseName(for a: Activity?, fileID: UInt32) -> String {
        guard let a else { return "activity_\(fileID.hex)" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: a.localOffset)
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return "\(f.string(from: a.startTime))_\(a.sport?.name ?? "activity")"
    }

    /// Converts ttbin bytes into a FIT file next to it in `fitDir`.
    @discardableResult
    public static func convert(ttbin data: [UInt8], to fitURL: URL, serialNumber: UInt32? = nil) throws -> Activity {
        let a = try TTBinParser.parse(data)
        try Data(ActivityFIT.encode(a, serialNumber: serialNumber)).write(to: fitURL, options: .atomic)
        return a
    }

    /// Downloads every activity from the watch, stores the raw ttbin and a FIT
    /// conversion under `root`, and optionally deletes the activity from the
    /// watch once the raw file is safely on disk (read back and compared).
    public static func exportAll(watch: Watch, root: URL = defaultRoot, deleteAfterExport: Bool,
                                 log: SyncLog) throws -> [ExportResult] {
        let fm = FileManager.default
        let ttbinDir = root.appendingPathComponent("ttbin"), fitDir = root.appendingPathComponent("fit")
        try fm.createDirectory(at: ttbinDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: fitDir, withIntermediateDirectories: true)

        let files = try watch.listFiles(type: FileID.ttbinType)
        log("\(files.count) activit\(files.count == 1 ? "y" : "ies") on the watch")
        let serial = watch.transport.serialNumber.flatMap { UInt32($0, radix: 16) }

        var results: [ExportResult] = []
        for (i, f) in files.enumerated() {
            log("[\(i + 1)/\(files.count)] Reading \(f.id.hex) (\(f.size / 1024) kB)…")
            let data = try watch.readFile(f.id)
            let activity = try? TTBinParser.parse(data)
            let base = baseName(for: activity, fileID: f.id)

            let ttbinURL = ttbinDir.appendingPathComponent(base + ".ttbin")
            try Data(data).write(to: ttbinURL, options: .atomic)
            let safe = (try? Data(contentsOf: ttbinURL)) == Data(data)

            var fitURL: URL?
            do {
                let url = fitDir.appendingPathComponent(base + ".fit")
                try convert(ttbin: data, to: url, serialNumber: serial)
                fitURL = url
                log("    → \(url.path)")
            } catch {
                log("    ⚠︎ FIT conversion failed (\(error)); raw ttbin kept at \(ttbinURL.path)")
            }

            var deleted = false
            if deleteAfterExport {
                if safe {
                    try watch.deleteFile(f.id)
                    deleted = true
                    log("    deleted from watch")
                } else {
                    log("    ⚠︎ not deleting: could not verify \(ttbinURL.lastPathComponent) on disk")
                }
            }
            results.append(ExportResult(ttbin: ttbinURL, fit: fitURL, activity: activity, deletedFromWatch: deleted))
        }
        return results
    }
}

// MARK: - GPS QuickFix

public enum QuickFix {
    /// TomTom still serves ephemeris data here; `days` must be 3, 7 or 14.
    public static func url(days: Int) -> URL {
        URL(string: "https://gpsquickfix.services.tomtom.com/fitness/sifgps.f2p\(days)enc.ee")!
    }

    public static func download(days: Int = 7) async throws -> [UInt8] {
        let (data, resp) = try await URLSession.shared.data(from: url(days: days))
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200, data.count > 1000 else {
            throw WatchError.badResponse("QuickFix download failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0), \(data.count) bytes)")
        }
        return [UInt8](data)
    }

    public static func upload(_ data: [UInt8], to watch: Watch, log: SyncLog) throws {
        log("Writing \(data.count / 1024) kB QuickFix data…")
        try watch.writeVerified(FileID.gpsQuickFix, data)
        try watch.resetGPSProcessor()
        log("GPS QuickFix updated")
    }
}

// MARK: - Time zone offset

public enum TimeSync {
    public struct Status {
        public var watchUTC: Date
        public var watchOffset: Int
        public var desiredOffset: Int
        public var clockDrift: TimeInterval
        public var needsUpdate: Bool { watchOffset != desiredOffset }
    }

    public static func status(watch: Watch, timeZone: TimeZone = .current) throws -> (Status, WatchSettings) {
        let settings = try WatchSettings(data: watch.readFile(FileID.manifest))
        guard let offset = settings.utcOffset else { throw WatchError.badResponse("watch settings have no utc_offset") }
        let watchUTC = try watch.currentTime()
        let now = Date()
        return (Status(watchUTC: watchUTC, watchOffset: offset, desiredOffset: timeZone.secondsFromGMT(for: now),
                       clockDrift: watchUTC.timeIntervalSince(now)), settings)
    }

    /// Writes the Mac's current UTC offset to the watch if it differs.
    /// The watch's UTC clock itself comes from GPS and is not changed.
    @discardableResult
    public static func sync(watch: Watch, log: SyncLog) throws -> Bool {
        var (st, settings) = try status(watch: watch)
        if abs(st.clockDrift) > 300 {
            log("Watch clock is \(Int(st.clockDrift))s off UTC; record an activity outdoors to sync it from GPS")
        }
        guard st.needsUpdate else {
            log("Time zone offset already correct (\(formatOffset(st.watchOffset)))")
            return false
        }
        _ = settings.setUTCOffset(st.desiredOffset)
        try watch.writeVerified(FileID.manifest, settings.data)
        log("Time zone offset updated \(formatOffset(st.watchOffset)) → \(formatOffset(st.desiredOffset))")
        return true
    }

    public static func formatOffset(_ s: Int) -> String {
        String(format: "UTC%@%02d:%02d", s < 0 ? "-" : "+", abs(s) / 3600, abs(s) % 3600 / 60)
    }
}

// MARK: - Exported activities on disk

public struct ExportedActivity: Identifiable, Sendable {
    public var id: String { fit.lastPathComponent }
    public var fit: URL
    public var start: Date
    public var sport: TTSport?
    public var distance: Double        // metres
    public var timerTime: TimeInterval
    public var activity: Activity

    /// Activities too short to be worth uploading (false starts).
    public var isTrivial: Bool { timerTime < 60 || distance < 10 }
}

extension Exporter {
    /// FIT files in `root/fit` with metadata from the matching ttbin, newest first.
    public static func exported(root: URL = defaultRoot) -> [ExportedActivity] {
        let fitDir = root.appendingPathComponent("fit"), ttbinDir = root.appendingPathComponent("ttbin")
        let fits = (try? FileManager.default.contentsOfDirectory(at: fitDir, includingPropertiesForKeys: nil)) ?? []
        return fits.filter { $0.pathExtension == "fit" }.compactMap { fit in
            let ttbin = ttbinDir.appendingPathComponent(fit.deletingPathExtension().lastPathComponent + ".ttbin")
            guard let data = try? Data(contentsOf: ttbin), let a = try? TTBinParser.parse([UInt8](data)) else { return nil }
            return ExportedActivity(fit: fit, start: a.startTime, sport: a.sport,
                                    distance: a.distance, timerTime: a.timerTime, activity: a)
        }.sorted { $0.start > $1.start }
    }
}

// MARK: - Full sync

public struct SyncOptions: Sendable {
    public var root = Exporter.defaultRoot
    public var deleteAfterExport = true
    public var quickFix = true
    public var timeSync = true
    public var stravaUpload = false
    public init() {}
}

public struct SyncSummary: Sendable {
    public var exported: [URL] = []
    public var uploaded: [(URL, Int64?)] = []
    public var quickFixUpdated = false
    public var timeZoneUpdated = false
    public var warnings: [String] = []
}

public enum SyncRunner {
    /// export → QuickFix → time zone → Strava upload of the newly exported files.
    /// Individual steps after the export log a warning instead of aborting.
    public static func run(_ o: SyncOptions, log: SyncLog, progress: ((Int, Int) -> Void)? = nil) async throws -> SyncSummary {
        var s = SyncSummary()
        let quickFixData: [UInt8]?
        if o.quickFix {
            do { quickFixData = try await QuickFix.download(days: 7) } catch {
                quickFixData = nil; s.warnings.append("QuickFix download failed: \(error)")
            }
        } else { quickFixData = nil }

        // All USB work happens on one connection, closed before uploading.
        do {
            let w = try Watch.connect()
            defer { w.close() }
            w.progress = progress
            log("Connected to TomTom \(w.model.name)")
            let results = try Exporter.exportAll(watch: w, root: o.root, deleteAfterExport: o.deleteAfterExport, log: log)
            s.exported = results.compactMap(\.fit)
            if let qf = quickFixData {
                do { try QuickFix.upload(qf, to: w, log: log); s.quickFixUpdated = true }
                catch { s.warnings.append("QuickFix upload failed: \(error)") }
            }
            if o.timeSync {
                do { s.timeZoneUpdated = try TimeSync.sync(watch: w, log: log) }
                catch { s.warnings.append("Time sync failed: \(error)") }
            }
        }

        if o.stravaUpload, !s.exported.isEmpty {
            do {
                let client = try StravaClient()
                var ledger = StravaLedger(root: o.root)
                let meta = Dictionary(Exporter.exported(root: o.root).map { ($0.fit.lastPathComponent, $0) }) { a, _ in a }
                for fit in s.exported where !ledger.contains(fit) {
                    if meta[fit.lastPathComponent]?.isTrivial ?? false {
                        log("Skipping \(fit.lastPathComponent) for Strava (under a minute)"); continue
                    }
                    log("Uploading \(fit.lastPathComponent) to Strava…")
                    let r = try await client.upload(fit: fit, description: meta[fit.lastPathComponent]?.activity.stravaDescription)
                    try ledger.record(fit, activityID: r.activityID)
                    s.uploaded.append((fit, r.activityID))
                }
            } catch {
                s.warnings.append("Strava upload failed: \(error)")
            }
        }
        for w in s.warnings { log("⚠︎ \(w)") }
        return s
    }
}
