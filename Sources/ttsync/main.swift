import Foundation
import Darwin
import TomTomKit

let usage = """
ttsync — TomTom sports watch sync for macOS

USAGE:
  ttsync info                      Show watch model, firmware, clock and file counts
  ttsync export [--delete] [--out DIR]
                                   Download activities as .ttbin + .fit (default DIR: ~/TomTom)
                                   --delete removes them from the watch after a verified save
  ttsync quickfix [--days 3|7|14]  Download GPS QuickFix data and upload it to the watch
  ttsync timesync                  Set the watch's time zone offset to this Mac's
  ttsync sync [--delete]           export + quickfix + timesync + routes (+ Strava upload when logged in)
  ttsync strava login --client-id ID [--client-secret SECRET]
                                   Connect to Strava (API app from strava.com/settings/api,
                                   Authorization Callback Domain: localhost). If omitted,
                                   the client secret is requested without terminal echo.
  ttsync strava status             Show Strava login and upload status
  ttsync strava upload [FILE.fit...]
                                   Upload FIT files (default: everything in ~/TomTom/fit not yet
                                   uploaded, skipping activities under a minute)
  ttsync strava logout
  ttsync routes [list]             Show the routes on the watch and in ~/TomTom/routes
  ttsync routes sync [--dry-run] [--no-strava]
                                   Download starred Strava routes (types as set in the app,
                                   default runs), then make the watch's routes match
                                   ~/TomTom/routes (15 max). The first sync saves the
                                   watch's routes there as GPX
  ttsync routes strava             List your Strava routes and which ones would be synced
  ttsync routes check FILE.gpx...  Show how GPX files would be converted (no watch needed)
  ttsync convert FILE.ttbin...     Convert ttbin files to FIT (no watch needed)
  ttsync files                     List all files on the watch (debug)
  ttsync dump FILEID OUT           Save a raw watch file, e.g. 0x00850000 (debug)
"""

let log = SyncLog { print($0) }
var args = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i); return true
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}

func connect() throws -> Watch {
    let w = try Watch.connect()
    print("Connected: TomTom \(w.model.name)\(w.transport.serialNumber.map { " (serial \($0))" } ?? "")")
    return w
}

func withProgress(_ w: Watch) {
    w.progress = { done, total in
        guard total > 4096 else { return }
        print(String(format: "\r    %3d%%", done * 100 / max(total, 1)), terminator: done == total ? "\r" : "")
        fflush(stdout)
    }
}

/// Reads a secret from the controlling terminal without placing it in shell
/// history or displaying it as the user types.
func readSecret(prompt: String) throws -> String {
    guard let value = getpass(prompt) else {
        throw NSError(domain: "TomTomSync", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not read the client secret from the terminal"])
    }
    return String(cString: value)
}

@MainActor func run() async throws {
    guard let cmd = args.first else { print(usage); return }
    args.removeFirst()
    switch cmd {
    case "info":
        let w = try connect()
        print("Firmware:   \(try w.firmwareVersion())")
        print("Product ID: \(String(format: "0x%x", try w.productID()))")
        let (st, _) = try TimeSync.status(watch: w)
        print("Watch UTC:  \(st.watchUTC) (drift \(Int(st.clockDrift))s)")
        print("Offset:     \(TimeSync.formatOffset(st.watchOffset)) (Mac: \(TimeSync.formatOffset(st.desiredOffset)))")
        let files = try w.listFiles()
        print("Activities: \(files.filter { $0.id & FileID.typeMask == FileID.ttbinType }.count)")
        print("Files:      \(files.count)")

    case "export":
        let delete = flag("--delete")
        let root = option("--out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Exporter.defaultRoot
        let w = try connect(); withProgress(w)
        let r = try Exporter.exportAll(watch: w, root: root, deleteAfterExport: delete, log: log)
        print("Exported \(r.count) activit\(r.count == 1 ? "y" : "ies") to \(root.path)")

    case "quickfix":
        let days = Int(option("--days") ?? "7") ?? 7
        guard [3, 7, 14].contains(days) else { throw WatchError.badResponse("--days must be 3, 7 or 14") }
        print("Downloading QuickFix data (\(days) days)…")
        let data = try await QuickFix.download(days: days)
        let w = try connect(); withProgress(w)
        try QuickFix.upload(data, to: w, log: log)

    case "timesync":
        try TimeSync.sync(watch: try connect(), log: log)

    case "sync":
        var o = SyncOptions()
        o.deleteAfterExport = flag("--delete")
        o.stravaUpload = StravaCredentials.load()?.isLoggedIn ?? false
        let w = Watch.isConnected
        if !w { throw TransportError.noDevice }
        let s = try await SyncRunner.run(o, log: log)
        print("Done: \(s.exported.count) exported, \(s.uploaded.count) uploaded to Strava")

    case "strava":
        try await strava()

    case "routes":
        try await routes()

    case "convert":
        guard !args.isEmpty else { print(usage); return }
        for path in args {
            let url = URL(fileURLWithPath: path)
            let out = url.deletingPathExtension().appendingPathExtension("fit")
            let a = try Exporter.convert(ttbin: [UInt8](try Data(contentsOf: url)), to: out)
            print("\(url.lastPathComponent): \(a.sport?.name ?? "?"), \(a.points.count) points, "
                  + String(format: "%.2f km, ", a.distance / 1000)
                  + "\(a.laps.count) laps → \(out.lastPathComponent)")
            if let d = a.stravaDescription { print("  " + d.replacingOccurrences(of: "\n", with: "\n  ")) }
        }

    case "files":
        let w = try connect()
        for f in try w.listFiles() { print("\(f.id.hex)  \(f.size)") }

    case "dump":
        guard args.count == 2, let id = UInt32(args[0].replacingOccurrences(of: "0x", with: ""), radix: 16) else {
            print(usage); return
        }
        let w = try connect(); withProgress(w)
        try Data(try w.readFile(id)).write(to: URL(fileURLWithPath: args[1]))
        print("Saved \(id.hex) to \(args[1])")

    default:
        print(usage)
    }
}

@MainActor func routes() async throws {
    let sub = args.first ?? "list"
    if !args.isEmpty { args.removeFirst() }
    switch sub {
    case "list":
        if Watch.isConnected {
            let w = try connect()
            if !RouteSync.supportsRoutes(w) { print("This watch doesn't support routes (no Trails menu)") }
            let files = try w.listFiles(type: RouteFile.fileType)
            print("On the watch (\(files.count)):")
            for f in files {
                if let r = try? RouteFile.decode(w.readFile(f.id)) {
                    print("  \(f.id.hex)  \(r.name)  " + String(format: "%.1f km, %d points", r.length / 1000, r.pointCount))
                } else {
                    print("  \(f.id.hex)  (unreadable, \(f.size) bytes)")
                }
            }
        } else {
            print("No watch connected")
        }
        listFolder()

    case "sync":
        let dryRun = flag("--dry-run")
        let settings = RouteSettings.load()
        if !flag("--no-strava"), !dryRun, let client = try? StravaClient(), client.credentials.isLoggedIn {
            let kinds = settings.stravaKinds.map(\.rawValue).sorted().joined(separator: ", ")
            print("Starred Strava routes: \(kinds.isEmpty ? "none" : kinds)")
            try await StravaRouteSync.sync(client: client, kinds: settings.stravaKinds, log: log)
        }
        let w = try connect(); withProgress(w)
        let s = try RouteSync.sync(watch: w, dryRun: dryRun, log: log)
        if !dryRun { print("Done: \(s.written) written, \(s.deleted) deleted, \(s.onWatch.count) on the watch") }

    case "strava":
        let client = try StravaClient()
        guard client.credentials.isLoggedIn else { throw StravaError.notLoggedIn }
        let settings = RouteSettings.load()
        let all = try await client.routes()
        let wanted = Set(StravaRouteSync.wanted(all, kinds: settings.stravaKinds).map(\.id))
        let kinds = settings.stravaKinds.map(\.rawValue).sorted().joined(separator: ", ")
        print("\(all.count) Strava route(s); syncing starred \(kinds.isEmpty ? "(none)" : kinds), newest first, 15 max")
        for r in all.sorted(by: { $0.createdAt > $1.createdAt }) {
            let mark = wanted.contains(r.id) ? "✓" : " "
            print("  \(mark) \(r.starred ? "★" : " ") \(r.kind?.rawValue ?? "?")\t\(r.name)\(r.isPrivate ? " (private)" : "")")
        }
        if !client.credentials.canReadPrivateRoutes {
            print("Private routes aren't included. Reconnect Strava (ttsync strava login) to allow them.")
        }

    case "check":
        guard !args.isEmpty else { print(usage); return }
        for path in args {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                let r = try GPX.read(url)
                let s = r.simplified(maximumPoints: RouteFile.maximumPoints)
                let bytes = RouteFile.encode(s.route, name: RouteFile.watchName(r.name))
                print("\(url.lastPathComponent): \"\(RouteFile.watchName(r.name))\", \(r.segments.count) segment(s), "
                      + s.summary + ", \(bytes.count) bytes")
            } catch {
                print("\(url.lastPathComponent): \(error)")
            }
        }

    default:
        print(usage)
    }
}

func listFolder() {
    let sel = RouteSync.select()
    print("In \(RouteSync.folder().path) (\(sel.chosen.count) to sync):")
    for c in sel.chosen { print("  \(c.watchName)\(c.fromStrava ? " (Strava)" : "")  \(c.simplified.summary)") }
    for c in sel.skipped { print("  doesn't fit: \(c.url.lastPathComponent)") }
    for url in sel.duplicates { print("  duplicate: \(url.lastPathComponent)") }
    for (url, error) in sel.failed { print("  skipped \(url.lastPathComponent): \(error)") }
}

@MainActor func strava() async throws {
    let sub = args.first ?? "status"
    if !args.isEmpty { args.removeFirst() }
    switch sub {
    case "login":
        var c = StravaCredentials.load() ?? StravaCredentials(clientID: "", clientSecret: "")
        if let id = option("--client-id") { c.clientID = id }
        if let secret = option("--client-secret") { c.clientSecret = secret }
        else if c.clientSecret.isEmpty { c.clientSecret = try readSecret(prompt: "Strava client secret: ") }
        guard !c.clientID.isEmpty, !c.clientSecret.isEmpty else { throw StravaError.notConfigured }
        try c.save()
        let client = StravaClient(credentials: c)
        print("Opening Strava in your browser… (waiting for authorization)")
        try await client.login { url in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = [url.absoluteString]
            try? p.run()
        }
        print("Connected to Strava as \(client.credentials.athlete ?? "athlete")")

    case "status":
        guard let c = StravaCredentials.load() else { throw StravaError.notConfigured }
        print(c.isLoggedIn ? "Logged in as \(c.athlete ?? "athlete")" : "Not logged in")
        let ledger = StravaLedger()
        for a in Exporter.exported() {
            let state = ledger.activityID(a.fit).map { "uploaded \(StravaClient.activityURL($0))" }
                ?? (ledger.contains(a.fit) ? "uploaded" : a.isTrivial ? "skipped (too short)" : "not uploaded")
            print("\(a.fit.lastPathComponent)  \(state)")
        }

    case "upload":
        let client = try StravaClient()
        var ledger = StravaLedger()
        let all = Exporter.exported()
        let meta = Dictionary(all.map { ($0.fit.lastPathComponent, $0) }) { a, _ in a }
        let files: [URL] = args.isEmpty
            ? all.filter { !ledger.contains($0.fit) && !$0.isTrivial }.map(\.fit).reversed()
            : args.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        if files.isEmpty { print("Nothing to upload") }
        for f in files {
            print("Uploading \(f.lastPathComponent)…", terminator: " "); fflush(stdout)
            let r = try await client.upload(fit: f, description: meta[f.lastPathComponent]?.activity.stravaDescription)
            try ledger.record(f, activityID: r.activityID)
            switch r {
            case .created(let id): print("→ \(StravaClient.activityURL(id))")
            case .duplicate(let id): print("already on Strava\(id.map { " (\(StravaClient.activityURL($0)))" } ?? "")")
            }
        }

    case "logout":
        if let c = StravaCredentials.load() { await StravaClient(credentials: c).logout() }
        print("Logged out of Strava")

    default:
        print(usage)
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
