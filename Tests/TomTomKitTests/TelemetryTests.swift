import Foundation
import Testing
@testable import TomTomKit

@Suite struct TelemetryTests {
    @Test func hashesTheInstallID() {
        let a = Telemetry.clientUser(installID: "8E4C1B2A-0000-4000-8000-000000000000")
        #expect(a.count == 64 && a.allSatisfy(\.isHexDigit))
        #expect(a == Telemetry.clientUser(installID: "8E4C1B2A-0000-4000-8000-000000000000"))
        #expect(a != Telemetry.clientUser(installID: "other"))
        #expect(!a.contains("8E4C1B2A"))
    }

    @Test func sendsOnlyTheDocumentedFields() throws {
        let info = Telemetry.Info(appVersion: "0.2.0", macOSVersion: "27.0", watchProductID: "0x07DE", stravaConnected: true)
        let body = try Telemetry.body(info, installID: "id", testMode: false, date: Date(timeIntervalSince1970: 0))
        let events = try #require(try JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        #expect(events.count == 1)
        let e = events[0]
        #expect(Set(e.keys) == ["appID", "clientUser", "receivedAt", "type", "sessionID", "isTestMode",
                                "TelemetryDeck.AppInfo.version", "TelemetryDeck.Device.operatingSystem",
                                "TelemetryDeck.Device.systemVersion", "TomTomSync.stravaConnected",
                                "TomTomSync.watchProductID"])
        #expect(e["type"] as? String == "App.active")
        #expect(e["isTestMode"] as? String == "false")
        #expect(e["receivedAt"] as? String == "1970-01-01T00:00:00Z")
        #expect(e["clientUser"] as? String == Telemetry.clientUser(installID: "id"))

        let noWatch = Telemetry.Info(appVersion: "0.2.0", macOSVersion: "27.0", watchProductID: nil, stravaConnected: false)
        let e2 = try #require(try JSONSerialization.jsonObject(with: Telemetry.body(noWatch, installID: "id", testMode: true)) as? [[String: Any]])[0]
        #expect(e2["TomTomSync.watchProductID"] == nil && e2["isTestMode"] as? String == "true")
    }

    @Test func onlyOfficialReleasesSendLiveSignals() {
        #expect(Telemetry.mode(build: "v0.2.0", official: true, testSignals: false) == .live)
        // A fork's release, or a local build at a tag: nothing.
        #expect(Telemetry.mode(build: "v0.2.0", official: false, testSignals: false) == .off)
        #expect(Telemetry.mode(build: "v0.1.0-3-gabc123", official: true, testSignals: false) == .off)
        // The development switch only ever gives test signals.
        #expect(Telemetry.mode(build: "v0.2.0", official: false, testSignals: true) == .test)
        #expect(Telemetry.mode(build: "dev", official: false, testSignals: true) == .test)
    }

    @Test func onlyExactReleaseTagsCountAsRealUse() {
        #expect(Telemetry.isRelease(build: "v0.2.0"))
        #expect(Telemetry.isRelease(build: "v1.10"))
        for dev in ["v0.1.0-3-gabc123", "82530c9", "dev", "", "0.2.0", "v0.2.0-rc1"] {
            #expect(!Telemetry.isRelease(build: dev))
        }
    }
}
