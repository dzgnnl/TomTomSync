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
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fitURL.path)
        return a
    }

    /// Downloads every activity from the watch, stores the raw ttbin and a FIT
    /// conversion under `root`, and optionally deletes the activity from the
    /// watch once the raw file is safely on disk (read back and compared).
    ///
    /// An activity that can't be read or stored is reported through `onFailure`
    /// and skipped, so one bad file doesn't hold up the others. After two
    /// failures in a row the connection is assumed to be gone and the export
    /// stops; what was exported until then is still returned.
    public static func exportAll(watch: Watch, root: URL = defaultRoot, deleteAfterExport: Bool,
                                 log: SyncLog, onFailure: ((String) -> Void)? = nil) throws -> [ExportResult] {
        let fm = FileManager.default
        let ttbinDir = root.appendingPathComponent("ttbin"), fitDir = root.appendingPathComponent("fit")
        try fm.createDirectory(at: ttbinDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: fitDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // Tighten permissions on directories created by earlier versions too;
        // activity exports contain precise GPS tracks.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ttbinDir.path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fitDir.path)

        let files = try watch.listFiles(type: FileID.ttbinType)
        log("\(files.count) activit\(files.count == 1 ? "y" : "ies") on the watch")
        let serial = watch.transport.serialNumber.flatMap { UInt32($0, radix: 16) }

        var results: [ExportResult] = []
        var failuresInARow = 0
        for (i, f) in files.enumerated() {
            log("[\(i + 1)/\(files.count)] Reading \(f.id.hex) (\(f.size / 1024) kB)…")
            do {
                results.append(try export(f, watch: watch, serial: serial, ttbinDir: ttbinDir, fitDir: fitDir,
                                          deleteAfterExport: deleteAfterExport, log: log, onFailure: onFailure))
                failuresInARow = 0
            } catch {
                let message = "Activity \(f.id.hex) not exported: \(error)"
                log("    ⚠︎ \(message)")
                onFailure?(message)
                failuresInARow += 1
                if failuresInARow == 2 {
                    if i + 1 < files.count { onFailure?("Export stopped; \(files.count - i - 1) more activit\(files.count - i - 1 == 1 ? "y" : "ies") left on the watch") }
                    break
                }
            }
        }
        return results
    }

    private static func export(_ f: WatchFile, watch: Watch, serial: UInt32?, ttbinDir: URL, fitDir: URL,
                               deleteAfterExport: Bool, log: SyncLog, onFailure: ((String) -> Void)?) throws -> ExportResult {
        let fm = FileManager.default
        let data = try watch.readFile(f.id)
        let activity = try? TTBinParser.parse(data)
        let base = baseName(for: activity, fileID: f.id)

        // The human-readable name has only second-level precision. If two
        // activities of the same sport share that timestamp, keep both
        // instead of silently replacing an earlier export.
        let uniqueBase = availableBaseName(base, for: data, fileID: f.id, ttbinDir: ttbinDir, fitDir: fitDir)
        let ttbinURL = ttbinDir.appendingPathComponent(uniqueBase + ".ttbin")
        try Data(data).write(to: ttbinURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ttbinURL.path)
        let safe = (try? Data(contentsOf: ttbinURL)) == Data(data)

        var fitURL: URL?
        do {
            let url = fitDir.appendingPathComponent(uniqueBase + ".fit")
            try convert(ttbin: data, to: url, serialNumber: serial)
            fitURL = url
            log("    → \((url.path as NSString).abbreviatingWithTildeInPath)")
        } catch {
            log("    ⚠︎ FIT conversion failed (\(error)); raw ttbin kept at \((ttbinURL.path as NSString).abbreviatingWithTildeInPath)")
            onFailure?("\(ttbinURL.lastPathComponent) could not be converted to FIT; the watch's file is kept in the ttbin folder")
        }

        var deleted = false
        if deleteAfterExport {
            if safe {
                // The activity is stored either way; it is exported again next time.
                do {
                    try watch.deleteFile(f.id)
                    deleted = true
                    log("    deleted from watch")
                } catch {
                    log("    ⚠︎ could not delete from watch: \(error)")
                    onFailure?("Activity \(f.id.hex) could not be deleted from the watch: \(error)")
                }
            } else {
                log("    ⚠︎ not deleting: could not verify \(ttbinURL.lastPathComponent) on disk")
            }
        }
        return ExportResult(ttbin: ttbinURL, fit: fitURL, activity: activity, deletedFromWatch: deleted)
    }

    /// `base`, or `base_<fileID>[_n]` when that name belongs to a different
    /// activity. Re-exporting the same ttbin (delete after export off) reuses
    /// its name, so repeated syncs don't create duplicates.
    static func availableBaseName(_ base: String, for data: [UInt8], fileID: UInt32,
                                  ttbinDir: URL, fitDir: URL) -> String {
        let fm = FileManager.default
        var suffix = 0
        while true {
            let candidate = suffix == 0 ? base : "\(base)_\(fileID.hex.dropFirst(2))\(suffix == 1 ? "" : "_\(suffix)")"
            let rawURL = ttbinDir.appendingPathComponent(candidate + ".ttbin")
            if fm.fileExists(atPath: rawURL.path) {
                if (try? Data(contentsOf: rawURL)) == Data(data) { return candidate }
            } else if !fm.fileExists(atPath: fitDir.appendingPathComponent(candidate + ".fit").path) {
                return candidate
            }
            suffix += 1
        }
    }
}

// MARK: - GPS QuickFix

public enum QuickFix {
    /// TomTom still serves ephemeris data here; `days` must be 3, 7 or 14.
    public static func url(days: Int) -> URL {
        URL(string: "https://gpsquickfix.services.tomtom.com/fitness/sifgps.f2p\(days)enc.ee")!
    }

    public static func download(days: Int = 7) async throws -> [UInt8] {
        // Stream the response so the size limit also bounds host memory if the
        // server or an intermediary returns an unexpectedly large body.
        let (bytes, response) = try await URLSession.shared.bytes(from: url(days: days))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw WatchError.badResponse("QuickFix download failed (\(status), HTTP status)")
        }
        let maximumSize = 512 * 1024
        var data: [UInt8] = []
        data.reserveCapacity(70 * 1024)
        for try await byte in bytes {
            guard data.count < maximumSize else {
                throw WatchError.badResponse("QuickFix download exceeded \(maximumSize) bytes")
            }
            data.append(byte)
        }
        guard data.count >= 1000 else {
            throw WatchError.badResponse("QuickFix download was too small (\(data.count) bytes)")
        }
        return data
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
    public var isTrivial: Bool {
        // Indoor activities have no distance; outdoors, a few metres is a false start.
        let indoor: Set<TTSport> = [.gym, .freestyle, .indoorCycling, .swimming]
        return timerTime < 60 || (distance < 10 && !(sport.map(indoor.contains) ?? false))
    }
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
    public var routes = RouteSettings.load()
    public init() {}
}

public struct SyncSummary: Sendable {
    public var exported: [URL] = []
    public var uploaded: [(URL, Int64?)] = []
    public var quickFixUpdated = false
    public var timeZoneUpdated = false
    public var routes: RouteSync.Summary?
    /// Product ID (USB message 0x20) of the synced watch.
    public var watchProductID: UInt32?
    public var warnings: [String] = []
}

/// FIT files that still have to go to Strava, kept in `strava-pending.json`.
/// Only files exported while Strava upload was on are listed.
struct PendingUploads {
    private(set) var files: [String]
    private let url: URL

    init(root: URL) {
        url = root.appendingPathComponent("strava-pending.json")
        files = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))) ?? []
        // Entries are used as file names in the fit folder.
        files.removeAll { $0.contains("/") || $0.hasPrefix(".") || !$0.hasSuffix(".fit") }
    }

    mutating func add(_ fits: [URL]) {
        let new = fits.map(\.lastPathComponent).filter { !files.contains($0) }
        guard !new.isEmpty else { return }
        files += new
        save()
    }

    mutating func remove(_ file: String) {
        guard files.contains(file) else { return }
        files.removeAll { $0 == file }
        save()
    }

    /// Set when the list could not be stored: the retry is then not guaranteed.
    private(set) var saveError: Error?

    private mutating func save() {
        do {
            if files.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                try JSONEncoder().encode(files).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            saveError = nil
        } catch { saveError = error }
    }
}

public enum SyncRunner {
    /// Strava routes → export → QuickFix → time zone → routes → Strava upload of the newly exported files.
    /// Individual steps after the export log a warning instead of aborting.
    public static func run(_ o: SyncOptions, log: SyncLog, progress: ((Int, Int) -> Void)? = nil) async throws -> SyncSummary {
        var s = SyncSummary()
        let quickFixData: [UInt8]?
        if o.quickFix {
            do { quickFixData = try await QuickFix.download(days: 7) } catch {
                quickFixData = nil; s.warnings.append("QuickFix download failed: \(error)")
            }
        } else { quickFixData = nil }

        // With no route kinds chosen this makes no API calls; it only removes
        // previously downloaded routes.
        if o.routes.enabled, let client = try? StravaClient(), client.credentials.isLoggedIn {
            do { try await StravaRouteSync.sync(client: client, kinds: o.routes.stravaKinds, root: o.root, log: log) }
            catch { s.warnings.append("Strava routes: \(error)") }
        }

        // All USB work happens on one connection, closed before uploading.
        do {
            let w = try Watch.connect()
            defer { w.close() }
            w.progress = progress
            log("Connected to TomTom \(w.model.name)")
            s.watchProductID = try? w.productID()
            var failures: [String] = []
            let results = try Exporter.exportAll(watch: w, root: o.root, deleteAfterExport: o.deleteAfterExport, log: log) {
                failures.append($0)
            }
            s.warnings += failures
            s.exported = results.compactMap(\.fit)
            if let qf = quickFixData {
                do { try QuickFix.upload(qf, to: w, log: log); s.quickFixUpdated = true }
                catch { s.warnings.append("QuickFix upload failed: \(error)") }
            }
            if o.timeSync {
                do { s.timeZoneUpdated = try TimeSync.sync(watch: w, log: log) }
                catch { s.warnings.append("Time sync failed: \(error)") }
            }
            if o.routes.enabled {
                do { s.routes = try RouteSync.sync(watch: w, root: o.root, log: log) }
                catch { s.warnings.append("Routes: \(error)") }
            }
        }

        if o.stravaUpload {
            // Uploads that fail (no network, Strava's rate limit) are retried at
            // the next sync: by then the activities are no longer on the watch.
            var pending = PendingUploads(root: o.root)
            pending.add(s.exported)
            let fitDir = o.root.appendingPathComponent("fit")
            let queue = pending.files.map { fitDir.appendingPathComponent($0) }
            if !queue.isEmpty {
                var ledger = StravaLedger(root: o.root)
                let meta = Dictionary(Exporter.exported(root: o.root).map { ($0.fit.lastPathComponent, $0) }) { a, _ in a }
                do {
                    let client = try StravaClient()
                    for fit in queue {
                        let name = fit.lastPathComponent
                        if ledger.contains(fit) || !FileManager.default.fileExists(atPath: fit.path) {
                            pending.remove(name); continue
                        }
                        if meta[name]?.isTrivial ?? false {
                            log("Skipping \(name) for Strava (too short)")
                            pending.remove(name); continue
                        }
                        log("Uploading \(name) to Strava…")
                        do {
                            let r = try await client.upload(fit: fit, description: meta[name]?.activity.stravaDescription)
                            try ledger.record(fit, activityID: r.activityID)
                            pending.remove(name)
                            s.uploaded.append((fit, r.activityID))
                        } catch StravaError.uploadFailed(let reason) {
                            // Strava refused this file; trying again won't help, the others can still go.
                            pending.remove(name)
                            s.warnings.append("Strava refused \(name): \(reason)")
                        }
                    }
                } catch {
                    let left = pending.files.count
                    s.warnings.append("Strava upload: \(error)" + (left > 0 && pending.saveError == nil
                        ? " (\(left) activit\(left == 1 ? "y" : "ies") will be tried again at the next sync)" : ""))
                }
                if let e = pending.saveError, !pending.files.isEmpty {
                    s.warnings.append("The list of activities still to upload could not be saved (\(e.localizedDescription)); "
                        + "upload them with the Upload button or `ttsync strava upload`")
                }
            }
        }
        for w in s.warnings { log("⚠︎ \(w)") }
        return s
    }
}
