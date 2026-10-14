import AppKit
import SwiftUI
import TomTomKit

/// Plain AppKit entry point. A SwiftUI `App` needs at least one scene, and with
/// only a `Settings` scene macOS showed an empty settings window on launch.
@main
@MainActor
enum TomTomSyncApp {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.mainMenu = mainMenu()
        app.run()
    }

    /// Never shown (the app has no menu bar of its own), but its key equivalents
    /// make ⌘C/⌘V/⌘A work in text fields, ⌘W close the settings window and ⌘Q quit.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector, String)]) {
            let menu = NSMenu(title: title)
            for (t, action, key) in items { menu.addItem(withTitle: t, action: action, keyEquivalent: key) }
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        }
        submenu("TomTomSync", [("Quit TomTomSync", #selector(NSApplication.terminate(_:)), "q")])
        submenu("File", [("Close", #selector(NSWindow.performClose(_:)), "w")])
        submenu("Edit", [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
                         ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                         ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")])
        return main
    }
}

/// Owns the menu bar item. An `NSStatusItem` with a fixed `autosaveName` (unlike
/// SwiftUI's `MenuBarExtra`) gives the item a stable identity, so menu bar
/// managers such as Bartender can recognize it and remember where it goes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    /// Created per opening: a closed NSPopover keeps its (hidden) window at
    /// menu bar level, which Bartender lists as a second TomTomSync item.
    private var popover: NSPopover?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "TomTomSync"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.setAccessibilityLabel("TomTomSync")

        updateIcon()
    }

    // Closing the settings window must not quit a menu bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Redraws the icon whenever the sync phase or connection state changes.
    private func updateIcon() {
        withObservationTracking {
            let syncing = model.phase == .syncing
            let image = NSImage(systemSymbolName: syncing ? "arrow.triangle.2.circlepath" : "figure.run",
                                accessibilityDescription: "TomTomSync")
            image?.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.appearsDisabled = !(model.watchConnected || syncing)
        } onChange: {
            Task { @MainActor [weak self] in self?.updateIcon() }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if let popover {
            popover.performClose(nil)
            return
        }
        let content = NSHostingController(rootView: MenuView(model: model) { [weak self] in self?.showSettings() })
        content.sizingOptions = .preferredContentSize
        let p = NSPopover()
        p.contentViewController = content
        p.behavior = .transient
        p.delegate = self
        popover = p
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        content.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil
        popover = nil
    }

    private func showSettings() {
        popover?.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "TomTomSync Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        // The window starts at the hosting view's initial (empty) frame; size it
        // to the form, whose height differs with and without a Strava login.
        if let w = settingsWindow, !w.isVisible, let view = w.contentViewController?.view {
            w.setContentSize(view.fittingSize)
            w.center()
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct MenuView: View {
    @Bindable var model: AppModel
    var openSettings: () -> Void
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let p = model.progress { ProgressView(value: p) }
            if showLog { logView }
            Divider()
            activityList
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(alignment: .top) {
            Image(systemName: model.watchConnected ? "applewatch.radiowaves.left.and.right" : "applewatch.slash")
                .font(.title2)
                .foregroundStyle(model.watchConnected ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.watchConnected ? "TomTom watch connected" : "No watch connected").font(.headline)
                Text(model.statusLine).font(.caption).foregroundStyle(statusColor).lineLimit(2)
                if let last = model.lastSync {
                    Text("Last sync \(last, format: .relative(presentation: .named))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await model.sync() }
            } label: {
                if model.phase == .syncing { ProgressView().controlSize(.small) } else { Text("Sync") }
            }
            .disabled(!model.watchConnected || model.phase == .syncing)
        }
        .contentShape(Rectangle())
        .onTapGesture { showLog.toggle() }
        .help("Click to show the sync log")
    }

    private var statusColor: Color {
        if case .failed = model.phase { return .red }
        return .secondary
    }

    private var logView: some View {
        ScrollView {
            Text(model.log.joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(height: 120)
        .padding(6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activities").font(.subheadline.weight(.semibold))
            if model.activities.isEmpty {
                Text("No exported activities yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.activities.prefix(20)) { a in ActivityRow(model: model, activity: a) }
                    }
                }
                .frame(maxHeight: 220)
            }
            if let m = model.stravaMessage {
                Text(m).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Folder") { model.openFolder() }
            Spacer()
            Button("Settings…", action: openSettings)
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

struct ActivityRow: View {
    let model: AppModel
    let activity: ExportedActivity

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.start, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    .font(.callout)
                Text(String(format: "%.2f km · %@", activity.distance / 1000, duration))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            strava
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var strava: some View {
        if let id = model.ledger.activityID(activity.fit) {
            Link(destination: StravaClient.activityURL(id)) { Label("Strava", systemImage: "checkmark.circle.fill").font(.caption) }
                .foregroundStyle(.orange)
        } else if model.ledger.contains(activity.fit) {
            Label("Uploaded", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        } else if model.uploading.contains(activity.id) {
            ProgressView().controlSize(.small)
        } else if model.strava?.isLoggedIn ?? false {
            Button("Upload") { Task { await model.upload(activity) } }
                .controlSize(.small)
        }
    }

    private var duration: String {
        let t = Int(activity.timerTime)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    private var icon: String {
        switch activity.sport {
        case .cycling, .indoorCycling: return "figure.outdoor.cycle"
        case .swimming: return "figure.pool.swim"
        case .hiking: return "figure.hiking"
        case .gym, .freestyle: return "figure.strengthtraining.traditional"
        case .skiing, .snowboarding: return "figure.skiing.downhill"
        default: return "figure.run"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var clientID = ""
    @State private var clientSecret = ""

    var body: some View {
        Form {
            Section("Sync") {
                Toggle("Sync automatically when the watch is connected", isOn: $model.autoSync)
                Toggle("Delete activities from the watch after export", isOn: $model.deleteAfterExport)
                Toggle("Update GPS QuickFix", isOn: $model.quickFix)
                Toggle("Set watch time zone to this Mac's", isOn: $model.timeSync)
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                LabeledContent("Export folder", value: Exporter.defaultRoot.path)
            }
            Section("Strava") {
                if let c = model.strava, c.isLoggedIn {
                    LabeledContent("Connected as", value: c.athlete ?? "athlete")
                    Toggle("Upload new activities automatically", isOn: $model.stravaAutoUpload)
                    Text("Activities shorter than a minute are not uploaded automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Disconnect Strava") { Task { await model.stravaLogout() } }
                } else {
                    Text("Create an API application at strava.com/settings/api with Authorization Callback Domain **localhost**, then paste its Client ID and Client Secret.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Client ID", text: $clientID)
                    SecureField("Client Secret", text: $clientSecret)
                    Button("Connect to Strava…") {
                        model.stravaConfigure(clientID: clientID, clientSecret: clientSecret)
                        Task { await model.stravaLogin() }
                    }
                    .disabled(clientID.isEmpty || clientSecret.isEmpty)
                }
                if let m = model.stravaMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            clientID = model.strava?.clientID ?? ""
            clientSecret = model.strava?.clientSecret ?? ""
        }
    }
}
