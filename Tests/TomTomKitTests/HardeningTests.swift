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
