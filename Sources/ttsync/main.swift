import Foundation
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
  ttsync sync [--delete]           export + quickfix + timesync
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
        let delete = flag("--delete")
        let qf = try? await QuickFix.download(days: 7)
        let w = try connect(); withProgress(w)
        _ = try Exporter.exportAll(watch: w, deleteAfterExport: delete, log: log)
        if let qf { try QuickFix.upload(qf, to: w, log: log) } else { print("⚠︎ QuickFix download failed; skipped") }
        try TimeSync.sync(watch: w, log: log)

    case "convert":
        guard !args.isEmpty else { print(usage); return }
        for path in args {
            let url = URL(fileURLWithPath: path)
            let out = url.deletingPathExtension().appendingPathExtension("fit")
            let a = try Exporter.convert(ttbin: [UInt8](try Data(contentsOf: url)), to: out)
            print("\(url.lastPathComponent): \(a.sport?.name ?? "?"), \(a.points.count) points, "
                  + String(format: "%.2f km, ", (a.summaryDistance ?? 0) / 1000)
                  + "\(a.laps.count) laps → \(out.lastPathComponent)")
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

do {
    try await run()
} catch {
    FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
