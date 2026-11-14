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
    var stravaLoggingIn = false
    /// Routes result of the last sync with a watch that supports them.
    var routes: RouteSync.Summary?
    var update: UpdateCheck.Release?

    // Settings
    var autoSync: Bool { didSet { save("autoSync", autoSync) } }
    var deleteAfterExport: Bool { didSet { save("deleteAfterExport", deleteAfterExport) } }
    var quickFix: Bool { didSet { save("quickFix", quickFix) } }
    var timeSync: Bool { didSet { save("timeSync", timeSync) } }
    var stravaAutoUpload: Bool { didSet { save("stravaAutoUpload", stravaAutoUpload) } }
    var routeSettings = RouteSettings.load() { didSet { routeSettings.save() } }
    var shareUsage: Bool { didSet { save("shareUsage", shareUsage) } }
    var checkForUpdates: Bool {
        didSet { save("checkForUpdates", checkForUpdates); if checkForUpdates { startUpdateChecks() } else { stopUpdateChecks() } }
    }
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { stravaMessage = nil; append("Launch at login: \(error.localizedDescription)") }
        }
    }

    @ObservationIgnored private var monitor: WatchMonitor?
    @ObservationIgnored private var pendingSync: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var telemetryTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        Self.migrateDefaults(into: d)
        d.register(defaults: ["autoSync": true, "deleteAfterExport": true, "quickFix": true,
                              "timeSync": true, "stravaAutoUpload": true, "checkForUpdates": true,
                              "shareUsage": true])
        autoSync = d.bool(forKey: "autoSync")
        deleteAfterExport = d.bool(forKey: "deleteAfterExport")
        quickFix = d.bool(forKey: "quickFix")
        timeSync = d.bool(forKey: "timeSync")
        stravaAutoUpload = d.bool(forKey: "stravaAutoUpload")
        checkForUpdates = d.bool(forKey: "checkForUpdates")
        shareUsage = d.bool(forKey: "shareUsage")
        lastSync = d.object(forKey: "lastSync") as? Date
        reloadActivities()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        monitor = WatchMonitor { [weak self] connected in
            Task { @MainActor in self?.watchChanged(connected) }
        }
        if checkForUpdates { startUpdateChecks() }
        startTelemetry()
    }

    /// Up to v0.1.0 the bundle ID was nl.takobruinsma.TomTomSync; carry its
    /// settings over once.
    private static func migrateDefaults(into d: UserDefaults) {
        let old = "nl.takobruinsma.TomTomSync"
        guard Bundle.main.bundleIdentifier != old, !d.bool(forKey: "migratedDefaults"),
              let values = UserDefaults.standard.persistentDomain(forName: old) else { return }
        for (k, v) in values where d.object(forKey: k) == nil && !k.hasPrefix("NS") { d.set(v, forKey: k) }
        d.set(true, forKey: "migratedDefaults")
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
        o.routes = routeSettings

        let logger = SyncLog { [weak self] line in Task { @MainActor [weak self] in self?.append(line) } }
        let onProgress: (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor [weak self] in self?.progress = total > 4096 && done < total ? Double(done) / Double(total) : nil }
        }
        do {
            let s = try await Task.detached { try await SyncRunner.run(o, log: logger, progress: onProgress) }.value
            lastSync = Date()
            if let id = s.watchProductID {
                UserDefaults.standard.set(String(format: "0x%04X", id), forKey: "lastWatchProductID")
            }
            phase = .idle
            progress = nil
            reloadActivities()
            strava = StravaCredentials.load()   // the sync may have refreshed the token
            var parts = ["\(s.exported.count) activit\(s.exported.count == 1 ? "y" : "ies") exported"]
            if !s.uploaded.isEmpty { parts.append("\(s.uploaded.count) uploaded to Strava") }
            if s.quickFixUpdated { parts.append("GPS QuickFix updated") }
            if let r = s.routes, r.written + r.deleted > 0 { parts.append("routes updated") }
            if let r = s.routes, r.supported { routes = r }
            let summary = parts.joined(separator: ", ")
            statusLine = s.warnings.isEmpty ? "Synced: \(summary)" : "Synced with warnings"
            notify(title: "TomTom synced", body: summary + (s.warnings.isEmpty ? "" : "\n" + s.warnings.joined(separator: "\n")))
        } catch {
            phase = .failed("\(error)")
            progress = nil
            reloadActivities()   // activities exported before the failure
            strava = StravaCredentials.load()
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
        guard let c = strava, !stravaLoggingIn else { return }
        stravaLoggingIn = true
        defer { stravaLoggingIn = false }
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

    func stravaLogout() async {
        guard let c = strava else { return }
        await StravaClient(credentials: c).logout()
        strava = StravaCredentials.load()
    }

    func upload(_ a: ExportedActivity) async {
        // A sync or `ttsync` may have refreshed the token or uploaded since.
        strava = StravaCredentials.load()
        guard let c = strava, c.isLoggedIn else { return }
        uploading.insert(a.id)
        defer { uploading.remove(a.id) }
        let client = StravaClient(credentials: c)
        do {
            let r = try await client.upload(fit: a.fit, description: a.activity.stravaDescription)
            ledger = StravaLedger()
            try ledger.record(a.fit, activityID: r.activityID)
            strava = client.credentials
            stravaMessage = nil
        } catch {
            stravaMessage = "\(error)"
        }
    }

    // MARK: Updates

    /// The running version, e.g. "0.1.0"; nil when not run from an app bundle.
    static var version: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

    /// Checks shortly after launch and then once a day. Notifies once per new version.
    private func startUpdateChecks() {
        guard updateTask == nil, Self.version != nil else { return }
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await self?.checkUpdate()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    private func stopUpdateChecks() {
        updateTask?.cancel(); updateTask = nil
        update = nil
    }

    private func checkUpdate() async {
        guard let current = Self.version, let latest = try? await UpdateCheck.latest() else { return }
        guard UpdateCheck.isNewer(latest.version, than: current) else { update = nil; return }
        update = latest
        let d = UserDefaults.standard
        if d.string(forKey: "notifiedVersion") != latest.version {
            d.set(latest.version, forKey: "notifiedVersion")
            notify(title: "TomTomSync \(latest.version) is available",
                   body: "Update with: brew upgrade tomtomsync")
        }
    }

    /// A new GitHub issue with the feedback form, prefilled with version, macOS and watch.
    func openFeedback() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var c = URLComponents(string: "https://github.com/dzgnnl/TomTomSync/issues/new")!
        c.queryItems = [
            .init(name: "template", value: "feedback.yml"),
            .init(name: "version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
            .init(name: "macos", value: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            .init(name: "watch", value: UserDefaults.standard.string(forKey: "lastWatchProductID") ?? ""),
        ]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    // MARK: Usage statistics

    /// Explains the daily signal once, then sends it at most once a day while
    /// `shareUsage` is on. Nothing is sent before the notice has been shown.
    private func startTelemetry() {
        guard Telemetry.isConfigured, Bundle.main.bundleIdentifier != nil else { return }
        telemetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.showUsageNoticeOnce()
            while !Task.isCancelled {
                await self?.sendUsageIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func showUsageNoticeOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "usageNoticeShown") else { return }
        let alert = NSAlert()
        alert.messageText = "Help decide TomTomSync's future"
        alert.informativeText = """
            Once a day, TomTomSync sends an anonymous signal to TelemetryDeck (EU): the app \
            version, macOS version, watch model, whether Strava is connected, and a random \
            installation ID. Nothing about your activities, locations or accounts.

            It only shows how many people still use the app. You can turn it off any time \
            in Settings.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Turn Off")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn { shareUsage = false }
        d.set(true, forKey: "usageNoticeShown")
    }

    private func sendUsageIfDue() async {
        let d = UserDefaults.standard
        guard shareUsage, d.bool(forKey: "usageNoticeShown") else { return }
        let today = Calendar.current.startOfDay(for: Date())
        if let last = d.object(forKey: "usageSentDay") as? Date, last >= today { return }
        let installID = d.string(forKey: "installID") ?? {
            let id = UUID().uuidString; d.set(id, forKey: "installID"); return id
        }()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let info = Telemetry.Info(
            appVersion: Self.version ?? "?",
            macOSVersion: "\(os.majorVersion).\(os.minorVersion)",
            watchProductID: d.string(forKey: "lastWatchProductID"),
            stravaConnected: strava?.isLoggedIn ?? false)
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        do {
            try await Telemetry.send(info, installID: installID, testMode: !Telemetry.isRelease(build: build))
            d.set(today, forKey: "usageSentDay")
        } catch {
            // Try again in an hour; never bother the user about it.
        }
    }

    // MARK: Misc

    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func openFolder() {
        let dir = Exporter.defaultRoot.appendingPathComponent("fit")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(dir)
    }

    func openRoutesFolder() {
        let dir = RouteSync.folder()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}
