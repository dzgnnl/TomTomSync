import Foundation

/// Keeps `~/TomTom/routes/Strava/` in line with the athlete's starred Strava
/// routes of the chosen kinds. Only files listed in its index are ever
/// changed or removed.
public enum StravaRouteSync {
    public struct Summary: Sendable {
        public var downloaded: [String] = []
        public var removed: [String] = []
        public var failed: [String] = []
        public var unchanged = 0
    }

    struct Entry: Codable, Equatable { var file: String; var updated: Date }

    static func indexURL(root: URL) -> URL { RouteSync.stravaFolder(root: root).appendingPathComponent(".index.json") }

    static func loadIndex(root: URL) -> [String: Entry] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([String: Entry].self, from: Data(contentsOf: indexURL(root: root)))) ?? [:]
    }

    static func saveIndex(_ index: [String: Entry], root: URL) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(index).write(to: indexURL(root: root), options: .atomic)
    }

    /// Starred routes of the given kinds, newest first, at most what fits on a watch.
    public static func wanted(_ routes: [StravaRoute], kinds: Set<StravaRoute.Kind>) -> [StravaRoute] {
        Array(routes.filter { $0.starred && $0.kind.map(kinds.contains) == true }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(RouteFile.maximumRoutes))
    }

    @discardableResult
    public static func sync(client: StravaClient, kinds: Set<StravaRoute.Kind>, root: URL = Exporter.defaultRoot,
                            log: SyncLog) async throws -> Summary {
        let fm = FileManager.default
        let dir = RouteSync.stravaFolder(root: root)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let wanted = kinds.isEmpty ? [] : wanted(try await client.routes(), kinds: kinds)
        var index = loadIndex(root: root)
        var summary = Summary()

        // Remove routes that are no longer starred or of a chosen kind.
        let wantedIDs = Set(wanted.map(\.id))
        for (id, entry) in index where !wantedIDs.contains(id) {
            if isPlainFileName(entry.file) { try? fm.removeItem(at: dir.appendingPathComponent(entry.file)) }
            index[id] = nil
            summary.removed.append(entry.file)
        }
        // The index is saved after every change, so a failure later on never
        // leaves a downloaded file untracked (it would come back as a duplicate
        // and never be cleaned up).
        try saveIndex(index, root: root)

        let taken = { Set(index.values.map(\.file)) }
        for r in wanted {
            let existing = index[r.id]
            if let existing, existing.updated == r.updatedAt, fm.fileExists(atPath: dir.appendingPathComponent(existing.file).path) {
                summary.unchanged += 1; continue
            }
            // One route failing (deleted on Strava, unreadable GPX) doesn't stop the others.
            let gpx: Data
            do {
                gpx = try await client.routeGPX(id: r.id)
                _ = try GPX.parse(gpx, fallbackName: r.name)   // don't store something the sync can't read
            } catch {
                log("⚠︎ Strava route \(r.name) skipped: \(error)")
                summary.failed.append(r.name)
                continue
            }
            if let existing, isPlainFileName(existing.file) { try? fm.removeItem(at: dir.appendingPathComponent(existing.file)) }
            let file = fileName(r.name, taken: taken().subtracting(existing.map { [$0.file] } ?? []), in: dir)
            let url = dir.appendingPathComponent(file)
            do {
                try gpx.write(to: url, options: .atomic)
            } catch {
                log("⚠︎ Strava route \(r.name) not saved: \(error.localizedDescription)")
                summary.failed.append(r.name)
                if existing != nil { index[r.id] = nil; try saveIndex(index, root: root) }
                continue
            }
            // The selection ranks by creation date: use the route's.
            try? fm.setAttributes([.creationDate: r.createdAt, .modificationDate: r.updatedAt], ofItemAtPath: url.path)
            index[r.id] = Entry(file: file, updated: r.updatedAt)
            try saveIndex(index, root: root)
            summary.downloaded.append(r.name)
            log("Strava route \(r.name) downloaded")
        }
        if !summary.removed.isEmpty { log("\(summary.removed.count) Strava route(s) no longer starred, removed") }
        return summary
    }

    /// Index entries are used as paths: accept only a file directly in the folder.
    static func isPlainFileName(_ file: String) -> Bool {
        !file.isEmpty && !file.hasPrefix(".") && !file.contains("/")
    }

    static func fileName(_ name: String, taken: Set<String>, in dir: URL) -> String {
        let cleaned = name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }
        var base = String(cleaned).trimmingCharacters(in: .whitespaces)
        if base.isEmpty || base.hasPrefix(".") { base = "Route" }
        base = String(base.prefix(100))
        while base.utf8.count > 200 { base.removeLast() }   // file names are limited to 255 bytes
        var file = base + ".gpx", n = 2
        while taken.contains(file) || FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) {
            file = "\(base) \(n).gpx"; n += 1
        }
        return file
    }
}

/// Route settings, stored in the app's preferences so the CLI uses the same ones.
/// Route sync is off until the user turns it on: a watch without Trails accepts
/// route files without an error, so the app can't tell that it has no use for them.
public struct RouteSettings: Sendable {
    public var enabled: Bool
    public var stravaKinds: Set<StravaRoute.Kind>

    public static let suite = "nl.dzgn.TomTomSync"
    static let enabledKey = "routeSync", kindsKey = "stravaRouteKinds"

    /// The app's own defaults in the app; the same domain read as a suite elsewhere (CLI).
    public static var defaults: UserDefaults? {
        Bundle.main.bundleIdentifier == suite ? .standard : UserDefaults(suiteName: suite)
    }

    public static func load(_ d: UserDefaults? = defaults) -> RouteSettings {
        let kinds = (d?.stringArray(forKey: kindsKey) ?? ["run"]).compactMap(StravaRoute.Kind.init(rawValue:))
        return RouteSettings(enabled: d?.object(forKey: enabledKey) as? Bool ?? false, stravaKinds: Set(kinds))
    }

    public func save(_ d: UserDefaults? = defaults) {
        d?.set(enabled, forKey: Self.enabledKey)
        d?.set(StravaRoute.Kind.allCases.filter(stravaKinds.contains).map(\.rawValue), forKey: Self.kindsKey)
    }
}
