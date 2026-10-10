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
  ttsync sync [--delete]           export + quickfix + timesync (+ Strava upload when logged in)
  ttsync strava login --client-id ID [--client-secret SECRET]
                                   Connect to Strava (API app from strava.com/settings/api,
                                   Authorization Callback Domain: localhost). If omitted,
                                   the client secret is requested without terminal echo.
  ttsync strava status             Show Strava login and upload status
  ttsync strava upload [FILE.fit...]
                                   Upload FIT files (default: everything in ~/TomTom/fit not yet
                                   uploaded, skipping activities under a minute)
  ttsync strava logout
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
