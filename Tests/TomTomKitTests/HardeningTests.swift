import Foundation
import Testing
@testable import TomTomKit

@Suite struct HardeningTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tomtomsync-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func pendingUploadsSurviveBetweenSyncs() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var pending = PendingUploads(root: root)
        #expect(pending.files.isEmpty)
        pending.add([root.appendingPathComponent("fit/a.fit"), root.appendingPathComponent("fit/b.fit")])
        pending.add([root.appendingPathComponent("fit/a.fit")])
        #expect(PendingUploads(root: root).files == ["a.fit", "b.fit"])
        pending.remove("a.fit")
        #expect(PendingUploads(root: root).files == ["b.fit"])
        pending.remove("b.fit")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("strava-pending.json").path))
    }

    @Test func pendingUploadsIgnoreEntriesThatAreNotFitFileNames() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(["../x.fit", ".hidden.fit", "notes.txt", "ok.fit"])
            .write(to: root.appendingPathComponent("strava-pending.json"))
        #expect(PendingUploads(root: root).files == ["ok.fit"])
    }

    @Test func gpxWriteDropsControlCharacters() throws {
        let route = Route(name: "Bad\u{01}name\u{FFFF} & <more>", segments: [[.init(latitude: 52, longitude: 4.9), .init(latitude: 52.01, longitude: 4.9)]])
        let back = try GPX.parse(GPX.write(route), fallbackName: "x")
        #expect(back.name == "Badname & <more>")
    }

    @Test func gpxWithTooManyPointsIsRejected() {
        var s = "<gpx><trk><trkseg>"
        for i in 0...GPX.maximumPoints { s += "<trkpt lat=\"52\" lon=\"\(Double(i % 1000) / 1000)\"/>" }
        s += "</trkseg></trk></gpx>"
        #expect(throws: (any Error).self) { try GPX.parse(Data(s.utf8), fallbackName: "x") }
    }

    @Test func stravaFileNamesFitTheFileSystem() throws {
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = StravaRouteSync.fileName(String(repeating: "走", count: 150), taken: [], in: dir)
        #expect(name.utf8.count <= 255)
        try Data().write(to: dir.appendingPathComponent(name))
    }

    @Test func indexEntriesMustBePlainFileNames() {
        #expect(StravaRouteSync.isPlainFileName("Loop.gpx"))
        for bad in ["", "..", "../x.gpx", ".index.json", "a/b.gpx"] { #expect(!StravaRouteSync.isPlainFileName(bad)) }
    }
}

@Suite struct PluggedDevicesTests {
    @Test func onlyKnownWatchesCountAsConnected() {
        var d = PluggedDevices<String>()
        #expect(!d.watchConnected && d.unsupportedProductID == nil)

        d.plugged("band", productID: 0x7480)   // a TomTom Touch: same vendor, not a watch we know
        #expect(!d.watchConnected && d.unsupportedProductID == 0x7480)

        d.plugged("watch", productID: 0x7475)
        #expect(d.watchConnected && d.unsupportedProductID == nil)

        // Unplugging the other device doesn't disconnect the watch.
        d.unplugged("band")
        #expect(d.watchConnected)
        d.unplugged("watch")
        #expect(!d.watchConnected && d.unsupportedProductID == nil)
    }
}

@Suite struct WatchLockTests {
    @Test func oneConnectionAtATime() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ttsync-\(UUID().uuidString)/watch.lock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try WatchLock(url: url)
        #expect { try WatchLock(url: url) } throws: { error in
            if case TransportError.busy = error { return true }
            return false
        }
        first.release()
        _ = try WatchLock(url: url)
    }

    @Test func aLockThatIsDroppedIsReleased() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ttsync-\(UUID().uuidString)/watch.lock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do { _ = try WatchLock(url: url) }
        _ = try WatchLock(url: url)
    }
}

@Suite struct OAuthCallbackTests {
    /// The redirect goes to "localhost", which can mean 127.0.0.1 or ::1.
    @Test(arguments: ["127.0.0.1", "[::1]"]) func answersOnBothLoopbackAddresses(host: String) async throws {
        let port = UInt16.random(in: 20_000..<60_000)
        let query = try await LocalCallbackServer.waitForCallback(port: port, state: "s3", timeout: 10) {
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                _ = try? await URLSession.shared.data(from: URL(string: "http://\(host):\(port)/callback?state=s3&code=abc")!)
            }
        }
        #expect(query["code"] == "abc")
    }

    /// An IPv4 address of this Mac that is not loopback.
    private static func networkAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var p = list
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET),
                  i.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0, i.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    /// Only this Mac may deliver the login: nothing answers on a network address.
    @Test func ignoresOtherNetworkInterfaces() async throws {
        guard let lan = Self.networkAddress() else { return }   // no network: nothing to test
        let port = UInt16.random(in: 20_000..<60_000)
        await #expect(throws: StravaError.self) {
            _ = try await LocalCallbackServer.waitForCallback(port: port, state: "s3", timeout: 2) {
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    _ = try? await URLSession.shared.data(from: URL(string: "http://\(lan):\(port)/callback?state=s3&code=abc")!)
                }
            }
        }
    }
}
