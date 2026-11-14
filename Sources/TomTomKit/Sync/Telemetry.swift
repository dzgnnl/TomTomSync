import CryptoKit
import Foundation

/// Anonymous "still in use" signal, at most once a day, to TelemetryDeck
/// (https://telemetrydeck.com). Exactly what is sent is listed in the README
/// under Privacy. No third-party SDK: one HTTPS request built here.
public enum Telemetry {
    /// From the TelemetryDeck dashboard. Not secret: every client carries them.
    static let appID = "C7C31F70-A447-41A9-B98A-7C625C299BCE"
    static let namespace = "nl.dzgn"

    public static var isConfigured: Bool { !appID.isEmpty && !namespace.isEmpty }

    /// The release workflow builds from a tag, so `CFBundleVersion` is exactly
    /// "v1.2.3"; anything else (git describe output, a commit hash, "dev") isn't
    /// a release.
    public static func isRelease(build: String) -> Bool {
        build.range(of: #"^v\d+(\.\d+)*$"#, options: .regularExpression) != nil
    }

    public enum Mode: Sendable { case off, test, live }

    /// Info.plist key set by `build-app.sh` for builds made by this repository's
    /// release workflow.
    public static let officialBuildKey = "TTSOfficialBuild"
    /// Preference that makes any other build send test signals, for development:
    /// `defaults write nl.dzgn.TomTomSync usageTestSignals -bool true`.
    public static let testSignalsKey = "usageTestSignals"

    /// Only this project's own releases count as real use. Other builds (a
    /// local build, a fork's release) send nothing, so they don't inflate the
    /// numbers and their users aren't reporting to this project.
    public static func mode(build: String, official: Bool, testSignals: Bool) -> Mode {
        guard isConfigured else { return .off }
        if official && isRelease(build: build) { return .live }
        return testSignals ? .test : .off
    }

    /// What the daily signal contains. Nothing about activities, locations,
    /// Strava accounts, names or serial numbers.
    public struct Info: Sendable, Equatable {
        public var appVersion: String
        public var macOSVersion: String
        /// Product ID of the last watch synced, e.g. "0x07DE"; nil before the first sync.
        public var watchProductID: String?
        public var stravaConnected: Bool

        public init(appVersion: String, macOSVersion: String, watchProductID: String?, stravaConnected: Bool) {
            self.appVersion = appVersion
            self.macOSVersion = macOSVersion
            self.watchProductID = watchProductID
            self.stravaConnected = stravaConnected
        }
    }

    /// A random ID made once per installation, hashed before sending, so
    /// TelemetryDeck can count installations without knowing who they are.
    static func clientUser(installID: String) -> String {
        SHA256.hash(data: Data(("TomTomSync-" + installID).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func body(_ info: Info, installID: String, testMode: Bool, date: Date = Date()) throws -> Data {
        var event: [String: Any] = [
            "appID": appID,
            "clientUser": clientUser(installID: installID),
            "receivedAt": ISO8601DateFormatter().string(from: date),
            "type": "App.active",
            "sessionID": UUID().uuidString,
            "isTestMode": testMode ? "true" : "false",
            "TelemetryDeck.AppInfo.version": info.appVersion,
            "TelemetryDeck.Device.operatingSystem": "macOS",
            "TelemetryDeck.Device.systemVersion": info.macOSVersion,
            "TomTomSync.stravaConnected": info.stravaConnected,
        ]
        if let w = info.watchProductID { event["TomTomSync.watchProductID"] = w }
        return try JSONSerialization.data(withJSONObject: [event], options: [.sortedKeys])
    }

    /// For the usage signal and the update check: no cookies, no cache, and no
    /// language list or system details in the headers.
    static let plainSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpAdditionalHeaders = ["User-Agent": "TomTomSync", "Accept-Language": "en"]
        return URLSession(configuration: config)
    }()

    public static func send(_ info: Info, installID: String, testMode: Bool) async throws {
        guard isConfigured else { return }
        var req = URLRequest(url: URL(string: "https://nom.telemetrydeck.com/v3/\(namespace)/")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try body(info, installID: installID, testMode: testMode)
        let (_, response) = try await plainSession.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw WatchError.badResponse("telemetry: HTTP \(status)") }
    }
}
