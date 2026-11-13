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
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
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
        let ranked = own.sorted { $0.added > $1.added } + strava.sorted { $0.added > $1.added }
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
        case unreadableRoutes([UInt32], backup: URL)
        public var description: String {
            switch self {
            case .unreadableRoutes(let ids, let backup):
                return "Couldn't read route file(s) \(ids.map(\.hex).joined(separator: ", ")) on the watch. "
                    + "Not syncing routes, so they aren't deleted. Raw copies are in \(backup.path)."
            }
        }
    }

    public struct Summary: Sendable {
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
            return summary
        }
        let fm = FileManager.default
        let dir = folder(root: root)
        if !dryRun { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }

        let files = try readWatchRoutes(watch)
        let onWatch = files.mapValues(\.route)
        let serial = watch.transport.serialNumber ?? "watch"
        let marker = dir.appendingPathComponent(".imported-\(serial)")
        var pending: [(URL, Route)] = []   // dry run: imports that would be saved
        if !fm.fileExists(atPath: marker.path) {
            // Keep the original files too: the format was reverse engineered.
            let backup = dir.appendingPathComponent(".watch-backup-\(serial)")
            if !dryRun, !files.isEmpty {
                try fm.createDirectory(at: backup, withIntermediateDirectories: true)
                for (id, f) in files { try Data(f.bytes).write(to: backup.appendingPathComponent("\(id.hex).bin")) }
            }
            let unreadable = files.filter { $0.value.route == nil }.keys.sorted()
            if !unreadable.isEmpty { throw SyncError.unreadableRoutes(unreadable, backup: backup) }

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
            if !dryRun { try Data().write(to: marker) }
        }

        let selection = select(root: root, extra: pending)
        for (url, error) in selection.failed { log("⚠︎ Skipping \(url.lastPathComponent): \(error)") }
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

    private static func availableURL(in dir: URL, name: String, taken: Set<String>) -> URL {
        let base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let safe = base.isEmpty || base.hasPrefix(".") ? "Route" : base
        var url = dir.appendingPathComponent(safe + ".gpx"), n = 2
        while FileManager.default.fileExists(atPath: url.path) || taken.contains(url.lastPathComponent) {
            url = dir.appendingPathComponent("\(safe) \(n).gpx"); n += 1
        }
        return url
    }
}
