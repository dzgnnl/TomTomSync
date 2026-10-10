import SwiftUI
import TomTomKit

@main
struct TomTomSyncApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.phase == .syncing ? "arrow.triangle.2.circlepath" : "figure.run")
                .symbolRenderingMode(.hierarchical)
                .opacity(model.watchConnected || model.phase == .syncing ? 1 : 0.6)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

struct MenuView: View {
    @Bindable var model: AppModel
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
            SettingsLink { Text("Settings…") }
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
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
                    Button("Disconnect Strava") { model.stravaLogout() }
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
