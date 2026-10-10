import AppKit
import Foundation
import Observation
import ServiceManagement
import TomTomKit
import UserNotifications

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable { case idle, syncing, failed(String) }

    var watchConnected = false
    var phase: Phase = .idle
    var statusLine = "Waiting for watch"
    var progress: Double?
    var log: [String] = []
    var lastSync: Date? { didSet { UserDefaults.standard.set(lastSync, forKey: "lastSync") } }
    var activities: [ExportedActivity] = []
    var ledger = StravaLedger()
    var uploading: Set<String> = []
    var strava: StravaCredentials? = StravaCredentials.load()
    var stravaMessage: String?

    // Settings
    var autoSync: Bool { didSet { save("autoSync", autoSync) } }
    var deleteAfterExport: Bool { didSet { save("deleteAfterExport", deleteAfterExport) } }
    var quickFix: Bool { didSet { save("quickFix", quickFix) } }
    var timeSync: Bool { didSet { save("timeSync", timeSync) } }
    var stravaAutoUpload: Bool { didSet { save("stravaAutoUpload", stravaAutoUpload) } }
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { stravaMessage = nil; append("Launch at login: \(error.localizedDescription)") }
        }
    }

    @ObservationIgnored private var monitor: WatchMonitor?
    @ObservationIgnored private var pendingSync: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        d.register(defaults: ["autoSync": true, "deleteAfterExport": true, "quickFix": true,
                              "timeSync": true, "stravaAutoUpload": true])
        autoSync = d.bool(forKey: "autoSync")
        deleteAfterExport = d.bool(forKey: "deleteAfterExport")
        quickFix = d.bool(forKey: "quickFix")
        timeSync = d.bool(forKey: "timeSync")
        stravaAutoUpload = d.bool(forKey: "stravaAutoUpload")
        lastSync = d.object(forKey: "lastSync") as? Date
        reloadActivities()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        monitor = WatchMonitor { [weak self] connected in
            Task { @MainActor in self?.watchChanged(connected) }
        }
    }

    private func save(_ key: String, _ v: Bool) { UserDefaults.standard.set(v, forKey: key) }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        statusLine = line.trimmingCharacters(in: .whitespaces)
    }

    func reloadActivities() {
        activities = Exporter.exported()
        ledger = StravaLedger()
    }

    // MARK: Watch

    private func watchChanged(_ connected: Bool) {
        guard connected != watchConnected else { return }
        watchConnected = connected
        pendingSync?.cancel()
        if connected {
            statusLine = "Watch connected"
            // The watch needs a moment after enumeration before it answers.
            if autoSync {
                pendingSync = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    await self?.sync()
                }
            }
        } else if phase != .syncing {
            statusLine = "Waiting for watch"
        }
    }

    func sync() async {
        guard phase != .syncing else { return }
        phase = .syncing
        progress = nil
        log.removeAll()
        var o = SyncOptions()
        o.deleteAfterExport = deleteAfterExport
        o.quickFix = quickFix
        o.timeSync = timeSync
        o.stravaUpload = stravaAutoUpload && (strava?.isLoggedIn ?? false)

        let logger = SyncLog { line in Task { @MainActor [weak self] in self?.append(line) } }
        let onProgress: (Int, Int) -> Void = { done, total in
            Task { @MainActor [weak self] in self?.progress = total > 4096 && done < total ? Double(done) / Double(total) : nil }
        }
        do {
            let s = try await Task.detached { try await SyncRunner.run(o, log: logger, progress: onProgress) }.value
            lastSync = Date()
            phase = .idle
            progress = nil
            reloadActivities()
            var parts = ["\(s.exported.count) activit\(s.exported.count == 1 ? "y" : "ies") exported"]
            if !s.uploaded.isEmpty { parts.append("\(s.uploaded.count) uploaded to Strava") }
            if s.quickFixUpdated { parts.append("GPS QuickFix updated") }
            let summary = parts.joined(separator: ", ")
            statusLine = s.warnings.isEmpty ? "Synced: \(summary)" : "Synced with warnings"
            notify(title: "TomTom synced", body: summary + (s.warnings.isEmpty ? "" : "\n" + s.warnings.joined(separator: "\n")))
        } catch {
            phase = .failed("\(error)")
            progress = nil
            statusLine = "Sync failed"
            append("Error: \(error)")
            notify(title: "TomTom sync failed", body: "\(error)")
        }
    }

    // MARK: Strava

    func stravaConfigure(clientID: String, clientSecret: String) {
        var c = strava ?? StravaCredentials(clientID: "", clientSecret: "")
        c.clientID = clientID.trimmingCharacters(in: .whitespaces)
        c.clientSecret = clientSecret.trimmingCharacters(in: .whitespaces)
        do { try c.save(); strava = c } catch { stravaMessage = "\(error)" }
    }

    func stravaLogin() async {
        guard let c = strava else { return }
        stravaMessage = "Waiting for authorization in your browser…"
        let client = StravaClient(credentials: c)
        do {
            try await client.login { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            strava = client.credentials
            stravaMessage = nil
            NSApp.activate()
        } catch {
            stravaMessage = "\(error)"
        }
    }

    func stravaLogout() {
        guard let c = strava else { return }
        StravaClient(credentials: c).logout()
        strava = StravaCredentials.load()
    }

    func upload(_ a: ExportedActivity) async {
        guard let c = strava, c.isLoggedIn else { return }
        uploading.insert(a.id)
        defer { uploading.remove(a.id) }
        let client = StravaClient(credentials: c)
        do {
            let r = try await client.upload(fit: a.fit, description: a.activity.stravaDescription)
            try ledger.record(a.fit, activityID: r.activityID)
            strava = client.credentials
            stravaMessage = nil
        } catch {
            stravaMessage = "\(error)"
        }
    }

    // MARK: Misc

    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func openFolder() { NSWorkspace.shared.open(Exporter.defaultRoot.appendingPathComponent("fit")) }
}
