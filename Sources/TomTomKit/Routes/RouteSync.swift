import CryptoKit
import Foundation

/// Mirrors the routes folder to the watch.
///
/// `~/TomTom/routes/*.gpx` are the user's own routes; `~/TomTom/routes/Strava/`
/// is filled by the app. The watch holds at most 15: own routes first, then
/// Strava routes, each newest first. On the watch they are sorted by name.
public enum RouteSync {
    public static func folder(root: URL = Exporter.defaultRoot) -> URL { root.appendingPathComponent("routes") }
    public static func stravaFolder(root: URL = Exporter.defaultRoot) -> URL {
        folder(root: root).appendingPathComponent("Strava")
    }

    /// Product IDs (USB message 0x20) of watches known to lack route support.
    /// 0x07D5: original Spark Music (no Trails menu).
    static let productIDsWithoutRoutes: Set<UInt32> = [0x07d5]

    public static func supportsRoutes(_ watch: Watch) -> Bool {
        guard watch.model != .multisport else { return false }
        guard let id = try? watch.productID() else { return true }
        return !productIDsWithoutRoutes.contains(id)
    }

    public struct Candidate: Sendable {
        public var url: URL
        public var fromStrava: Bool
        public var added: Date
        public var watchName: String
        public var simplified: Route.Simplified
        /// The route exactly as the watch will store it.
        public var route: Route { Route(name: watchName, segments: simplified.route.segments) }
        /// `route` after an encode/decode round trip, with coordinates rounded
        /// like the copy on the watch. Used to compare with watch routes.
        var stored: Route? { try? RouteFile.decode(RouteFile.encode(route, name: watchName)) }
    }

    public struct Selection: Sendable {
        /// Sorted by name: the order on the watch.
        public var chosen: [Candidate] = []
        /// Didn't fit in the watch's 15 slots.
        public var skipped: [Candidate] = []
        public var failed: [(URL, String)] = []
        /// Same name and points as a route already chosen.
        public var duplicates: [URL] = []
    }

    /// Reads and ranks the GPX files in the routes folder. `extra` are routes
    /// treated as own files that don't exist yet (a dry run's imports).
    public static func select(root: URL = Exporter.defaultRoot, extra: [(URL, Route)] = []) -> Selection {
        var sel = Selection()
        var strava: [Candidate] = []
        var own = extra.map { url, route in
            Candidate(url: url, fromStrava: false, added: Date(), watchName: RouteFile.watchName(route.name),
                      simplified: route.simplified(maximumPoints: RouteFile.maximumPoints))
        }
        for (dir, fromStrava) in [(folder(root: root), false), (stravaFolder(root: root), true)] {
            // A missing folder is empty; one that exists but can't be read is a failure.
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
            } catch {
                sel.failed.append((dir, "can't read the folder: \(error.localizedDescription)"))
                continue
            }
            for url in urls where url.pathExtension.lowercased() == "gpx" {
                do {
                    let route = try GPX.read(url)
                    let added = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let c = Candidate(url: url, fromStrava: fromStrava, added: added,
                                      watchName: RouteFile.watchName(route.name),
                                      simplified: route.simplified(maximumPoints: RouteFile.maximumPoints))
                    if fromStrava { strava.append(c) } else { own.append(c) }
                } catch {
                    sel.failed.append((url, "\(error)"))
                }
            }
        }
        // The same route twice (e.g. a GPX exported from Strava and also starred
        // there) takes one slot; the own copy wins.
        var seen: [Route] = []
        let ranked = (own.sorted { $0.added > $1.added } + strava.sorted { $0.added > $1.added }).filter { c in
            guard let r = c.stored else { return true }
            if seen.contains(r) { sel.duplicates.append(c.url); return false }
            seen.append(r); return true
        }
        sel.chosen = Array(ranked.prefix(RouteFile.maximumRoutes))
            .sorted { $0.watchName.localizedStandardCompare($1.watchName) == .orderedAscending }
        sel.skipped = Array(ranked.dropFirst(RouteFile.maximumRoutes))
        return sel
    }

    public struct Plan: Sendable {
        public enum Step: Sendable {
            case keep(slot: Int, Candidate)
            case write(slot: Int, Candidate)
            case delete(fileID: UInt32, name: String?)
        }
        public var steps: [Step] = []
        public var changes: Int { steps.filter { if case .keep = $0 { false } else { true } }.count }
    }

    /// Slot i holds the i-th chosen route; route files beyond that are deleted.
    static func plan(_ selection: Selection, onWatch: [UInt32: Route?]) -> Plan {
        var plan = Plan()
        for (slot, c) in selection.chosen.enumerated() {
            let current = onWatch[RouteFile.fileID(slot: slot)] ?? nil
            plan.steps.append(current != nil && current == c.stored ? .keep(slot: slot, c) : .write(slot: slot, c))
        }
        let used = Set(selection.chosen.indices.map(RouteFile.fileID(slot:)))
        for id in onWatch.keys.sorted() where !used.contains(id) {
            plan.steps.append(.delete(fileID: id, name: (onWatch[id] ?? nil)?.name))
        }
        return plan
    }

    /// Route files on the watch: raw bytes and decoded route (`nil` when unreadable).
    static func readWatchRoutes(_ watch: Watch) throws -> [UInt32: (bytes: [UInt8], route: Route?)] {
        var out: [UInt32: (bytes: [UInt8], route: Route?)] = [:]
        for f in try watch.listFiles(type: RouteFile.fileType) {
            let bytes = try watch.readFile(f.id)
            out[f.id] = (bytes, try? RouteFile.decode(bytes))
        }
        return out
    }

    public enum SyncError: Error, CustomStringConvertible {
        case unreadableRoutes([UInt32], backup: URL?)
        case unreadableSources([(URL, String)])
        public var description: String {
            switch self {
            case .unreadableRoutes(let ids, let backup):
                return "Couldn't read route file(s) \(ids.map(\.hex).joined(separator: ", ")) on the watch. "
                    + "Not syncing routes, so they aren't deleted."
                    + (backup.map { " Raw copies are in \($0.path)." } ?? "")
            case .unreadableSources(let failed):
                return "Can't read " + failed.map { "\($0.0.lastPathComponent) (\($0.1))" }.joined(separator: ", ")
                    + ". Routes on the watch are left unchanged until it is fixed or removed."
            }
        }
    }

    public struct Summary: Sendable {
        /// False for watches without route support; nothing else is filled in then.
        public var supported = true
        public var onWatch: [String] = []
        public var written = 0
        public var deleted = 0
        public var imported: [URL] = []
        public var skipped: [String] = []
    }

    /// Mirrors the folder to the watch. The first time a watch is synced, its
    /// routes that aren't in the folder are saved there as GPX first, so
    /// nothing is lost.
    @discardableResult
    public static func sync(watch: Watch, root: URL = Exporter.defaultRoot, dryRun: Bool = false,
                            log: SyncLog) throws -> Summary {
        var summary = Summary()
        guard supportsRoutes(watch) else {
            log("This watch doesn't support routes (no Trails menu); skipping")
            summary.supported = false
            return summary
        }
        let fm = FileManager.default
        let dir = folder(root: root)
        if !dryRun { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }

        let files = try readWatchRoutes(watch)
        let onWatch = files.mapValues(\.route)
        // Without a serial the watch can't be told apart from others, so it is
        // never marked as imported: its unknown routes are saved on every sync.
        let serial = pathSafe(serial: watch.transport.serialNumber)
        let marker = serial.map { dir.appendingPathComponent(".imported-\($0)") }
        var pending: [(URL, Route)] = []   // dry run: imports that would be saved
        let firstSync = marker.map { !fm.fileExists(atPath: $0.path) } ?? true
        let backup = dir.appendingPathComponent(".watch-backup-\(serial ?? "unknown")")
        func saveBackup(_ ids: some Sequence<UInt32>, suffix: String = "") throws {
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            for id in ids { try Data(files[id]!.bytes).write(to: backup.appendingPathComponent("\(id.hex)\(suffix).bin")) }
        }
        // Keep the original files of a new watch: the format was reverse engineered.
        if firstSync, !dryRun, !files.isEmpty { try saveBackup(files.keys) }
        // Never overwrite or delete a route file we can't read, on any sync.
        let unreadable = files.filter { $0.value.route == nil }.keys.sorted()
        if !unreadable.isEmpty {
            if !dryRun, !firstSync {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
                try saveBackup(unreadable, suffix: "-" + stamp)
            }
            throw SyncError.unreadableRoutes(unreadable, backup: dryRun ? nil : backup)
        }
        if firstSync {

            let inFolder = select(root: root)
            let known = (inFolder.chosen + inFolder.skipped).compactMap(\.stored)
            var used = Set<String>()
            for (id, route) in onWatch.sorted(by: { $0.key < $1.key }) {
                guard let route, !known.contains(route) else { continue }
                let url = availableURL(in: dir, name: route.name, taken: used)
                used.insert(url.lastPathComponent)
                if dryRun {
                    log("Would save \(route.name) (\(id.hex)) from the watch as \(url.lastPathComponent)")
                    pending.append((url, route))
                } else {
                    try GPX.write(route).write(to: url, options: .atomic)
                    log("Saved \(route.name) from the watch as \(url.lastPathComponent)")
                }
                summary.imported.append(url)
            }
            if !dryRun, let marker { try Data().write(to: marker) }
        }

        let selection = select(root: root, extra: pending)
        // A route we can't read might be one that is on the watch now: stop
        // rather than overwrite or delete it.
        if !selection.failed.isEmpty { throw SyncError.unreadableSources(selection.failed) }
        for c in selection.skipped { log("Doesn't fit on the watch (15 routes max): \(c.url.lastPathComponent)") }
        summary.skipped = selection.skipped.map(\.watchName)

        let plan = plan(selection, onWatch: onWatch)
        for step in plan.steps {
            switch step {
            case .keep(_, let c):
                summary.onWatch.append(c.watchName)
            case .write(let slot, let c):
                if dryRun {
                    log("Would write \(c.watchName) (\(c.simplified.summary))")
                } else {
                    let id = RouteFile.fileID(slot: slot)
                    if onWatch[id] != nil { try watch.deleteFile(id) }
                    try watch.writeVerified(id, RouteFile.encode(c.route, name: c.watchName))
                    log("Route \(c.watchName) written (\(c.simplified.summary))")
                }
                summary.onWatch.append(c.watchName); summary.written += 1
            case .delete(let id, let name):
                if dryRun {
                    log("Would delete \(name ?? id.hex) from the watch")
                } else {
                    try watch.deleteFile(id)
                    log("Route \(name ?? id.hex) deleted from the watch")
                }
                summary.deleted += 1
            }
        }
        if plan.changes == 0 { log("Routes up to date (\(summary.onWatch.count) on the watch)") }
        return summary
    }

    /// The serial as a file name part: letters, digits, "-" and "_" only, so a
    /// device can't steer the marker or backup paths outside the routes folder.
    /// If that changed the serial, a hash of the original keeps different
    /// serials apart. nil when the watch reports no serial.
    static func pathSafe(serial: String?) -> String? {
        guard let serial, !serial.isEmpty else { return nil }
        let kept = String(serial.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }.map(Character.init).prefix(64))
        guard kept != serial else { return kept }
        let hash = SHA256.hash(data: Data(serial.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return (kept.isEmpty ? "x" : kept) + "-" + hash
    }

    private static func availableURL(in dir: URL, name: String, taken: Set<String>) -> URL {
        let base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        var safe = base.isEmpty || base.hasPrefix(".") ? "Route" : base
        while safe.utf8.count > 200 { safe.removeLast() }   // file names are limited to 255 bytes
        var url = dir.appendingPathComponent(safe + ".gpx"), n = 2
        while FileManager.default.fileExists(atPath: url.path) || taken.contains(url.lastPathComponent) {
            url = dir.appendingPathComponent("\(safe) \(n).gpx"); n += 1
        }
        return url
    }
}
