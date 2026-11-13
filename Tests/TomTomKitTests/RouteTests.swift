import Foundation
import Testing
@testable import TomTomKit

private func pt(_ lat: Double, _ lon: Double) -> Route.Point { Route.Point(latitude: lat, longitude: lon) }

/// A straight line north with an out-and-back spur east halfway: the spur's tip
/// is far from every chord and must survive simplification.
private func spurRoute(points: Int = 2000) -> Route {
    var seg: [Route.Point] = []
    for i in 0..<points {
        let t = Double(i) / Double(points - 1)
        let spur = max(0, 0.02 - abs(t - 0.5)) * 0.1     // up to 0.002° (≈140 m) east
        seg.append(pt(52.0 + t * 0.05, 4.9 + spur))
    }
    return Route(name: "Spur", segments: [seg])
}

@Suite struct ProtobufTests {
    @Test func roundTripsFields() throws {
        var w = ProtoWriter()
        w.varint(1, 300)
        w.int32(2, -5)
        w.fixed32(3, 0x1234_daeb)
        w.string(4, "Amstel")
        w.message(5) { $0.fixed32(1, UInt32(bitPattern: -1)) }
        let f = try ProtoReader.fields(w.bytes)
        #expect(f.first(1)?.uint64 == 300)
        #expect(f.first(2)?.uint64.map { Int32(truncatingIfNeeded: Int64(bitPattern: $0)) } == -5)
        #expect(f.first(3)?.uint32 == 0x1234_daeb)
        #expect(f.first(4)?.string == "Amstel")
        #expect(try f.first(5)?.message().first(1)?.uint32 == 0xffff_ffff)
    }

    @Test func rejectsTruncatedInput() {
        var w = ProtoWriter()
        w.string(1, "a long enough string")
        #expect(throws: ProtoError.self) { try ProtoReader.fields(Array(w.bytes.dropLast(3))) }
    }
}

@Suite struct RouteFileTests {
    @Test func roundTripsIncludingNegativeCoordinates() throws {
        let route = Route(name: "x", segments: [[pt(-33.8688, 151.2093), pt(-33.87, 151.21)],
                                                 [pt(51.5, -0.12), pt(51.51, -0.13), pt(51.52, -0.14)]])
        let decoded = try RouteFile.decode(RouteFile.encode(route, name: "Mixed"))
        #expect(decoded.name == "Mixed")
        #expect(decoded.segments.map(\.count) == [2, 3])
        for (a, b) in zip(route.segments.flatMap { $0 }, decoded.segments.flatMap { $0 }) {
            #expect(abs(a.latitude - b.latitude) < 1e-7 && abs(a.longitude - b.longitude) < 1e-7)
        }
    }

    @Test func writesHeaderBoundingBoxAndTime() throws {
        let route = Route(name: "r", segments: [[pt(52.0, 4.8), pt(52.1, 4.9)]])
        let date = RouteFile.timeOrigin.addingTimeInterval(1000)
        let root = try ProtoReader.fields(RouteFile.encode(route, name: "r", date: date))
        #expect(root.all(1).count == 2)
        let meta = try root.all(1)[0].message().first(7)!.message()
        #expect(meta.first(1)?.uint32 == 0x1234_daeb && meta.first(2)?.uint32 == 0x0007_0100)

        let track = try root.all(1)[1].message().first(8)!.message().first(1)!.message()
        let info = try track.first(1)!.message()
        let box = try info.first(2)!.message().map { try $0.message().first(1)!.uint32! }
        #expect(box.map { Int32(bitPattern: $0) } == [520_000_000, 48_000_000, 521_000_000, 49_000_000])
        let time = info.first(3)!.bytes!
        #expect(time.count == 16 && time[0..<8].allSatisfy { $0 == 0 })
        #expect(time[8...].reduce(0) { $0 << 8 | UInt64($1) } == 3455)   // 1000 s × 3.45559
        // Start and end of the first segment, with index 1 and 2.
        #expect(try track.all(2).map { try $0.message().first(2)!.uint64! } == [1, 2])
    }

    @Test func rejectsOtherFiles() {
        var w = ProtoWriter()
        w.message(1) { c in c.message(7) { $0.fixed32(1, 1); $0.fixed32(2, 2) } }
        #expect(throws: (any Error).self) { try RouteFile.decode(w.bytes) }
        #expect(throws: (any Error).self) { try RouteFile.decode([0xff, 0xff, 0xff]) }
    }

    @Test func makesWatchNames() {
        #expect(RouteFile.watchName("Rondje Ouderkerk") == "Rondje Ouderkerk")
        #expect(RouteFile.watchName("  Côte d’Azur   🏃 loop ") == "Cote dAzur loop")
        #expect(RouteFile.watchName("🏃🏃") == "Route")
        #expect(RouteFile.watchName(String(repeating: "a", count: 50)).count == RouteFile.maximumNameLength)
    }
}

@Suite struct GPXTests {
    @Test func readsTrackSegmentsAndName() throws {
        let xml = """
        <?xml version="1.0"?>
        <gpx xmlns="http://www.topografix.com/GPX/1/1" version="1.1">
          <metadata><name>Metadata name</name></metadata>
          <wpt lat="1" lon="1"><name>Waypoint</name></wpt>
          <trk><name> Amstel loop </name>
            <trkseg><trkpt lat="52.30" lon="4.90"><ele>1</ele></trkpt><trkpt lat="52.31" lon="4.91"/></trkseg>
            <trkseg><trkpt lat="52.32" lon="4.92"/></trkseg>
          </trk>
        </gpx>
        """
        let r = try GPX.parse(Data(xml.utf8), fallbackName: "file")
        #expect(r.name == "Amstel loop")
        #expect(r.segments.map(\.count) == [2, 1])
    }

    @Test func readsRoutesAndFallsBackToMetadataOrFileName() throws {
        let rte = #"<gpx><metadata><name>Meta</name></metadata><rte><rtept lat="1" lon="2"/><rtept lat="1.1" lon="2.1"/></rte></gpx>"#
        let r = try GPX.parse(Data(rte.utf8), fallbackName: "file")
        #expect(r.name == "Meta" && r.pointCount == 2)
        let bare = #"<gpx><trk><trkseg><trkpt lat="1" lon="2"/></trkseg></trk></gpx>"#
        #expect(try GPX.parse(Data(bare.utf8), fallbackName: "file").name == "file")
    }

    @Test func rejectsEmptyAndInvalidFiles() {
        #expect(throws: GPXError.self) { try GPX.parse(Data("<gpx></gpx>".utf8), fallbackName: "") }
        #expect(throws: GPXError.self) { try GPX.parse(Data("<gpx><trk>".utf8), fallbackName: "") }
        let outOfRange = #"<gpx><trk><trkseg><trkpt lat="95" lon="2"/></trkseg></trk></gpx>"#
        #expect(throws: GPXError.self) { try GPX.parse(Data(outOfRange.utf8), fallbackName: "") }
    }

    @Test func writtenFilesReadBack() throws {
        let route = Route(name: "A & B <x>", segments: [[pt(52.1, 4.1), pt(52.2, 4.2)], [pt(-1, -2)]])
        #expect(try GPX.parse(GPX.write(route), fallbackName: "") == route)
    }
}

@Suite struct SimplifyTests {
    @Test func keepsShortRoutesUnchanged() {
        let r = Route(name: "r", segments: [[pt(1, 1), pt(1.1, 1.1)]])
        let s = r.simplified(maximumPoints: 500)
        #expect(s.route == r && s.maximumDeviation == 0)
    }

    @Test func keepsEndpointsAndTheTipOfAnOutAndBack() {
        let r = spurRoute()
        let s = r.simplified(maximumPoints: 20)
        let seg = s.route.segments[0]
        #expect(s.route.pointCount == 20)
        #expect(seg.first == r.segments[0].first && seg.last == r.segments[0].last)
        let tip = r.segments[0].max { $0.longitude < $1.longitude }!
        #expect(seg.contains(tip))
        // The length barely changes: corners are kept, not cut.
        #expect(abs(s.route.length - r.length) / r.length < 0.01)
    }

    @Test func reportsTheActualDeviation() {
        // A zigzag 10 m either side of a straight line, starting and ending on
        // the +10 m side: keeping only the ends leaves the −10 m points 20 m off.
        let mLon = 1 / (111_195 * cos(52 * Double.pi / 180))
        let seg = (0..<101).map { i in pt(52 + Double(i) * 0.001, 4.9 + (i % 2 == 0 ? 10 : -10) * mLon) }
        let s = Route(name: "z", segments: [seg]).simplified(maximumPoints: 2)
        #expect(abs(s.maximumDeviation - 20) < 0.5)
    }

    @Test func sharesPointsAcrossSegmentsAndKeepsTheirEnds() {
        let a = spurRoute(points: 600).segments[0]
        let b = (0..<10).map { pt(53 + Double($0) * 0.001, 5) }
        let s = Route(name: "two", segments: [a, b]).simplified(maximumPoints: 100)
        #expect(s.route.pointCount == 100)
        #expect(s.route.segments.count == 2)
        #expect(s.route.segments[1].first == b.first && s.route.segments[1].last == b.last)
    }
}

@Suite struct RouteSyncTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("routes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: RouteSync.stravaFolder(root: root), withIntermediateDirectories: true)
        return root
    }

    private func add(_ root: URL, _ name: String, strava: Bool = false, age: TimeInterval) throws {
        let dir = strava ? RouteSync.stravaFolder(root: root) : RouteSync.folder(root: root)
        let url = dir.appendingPathComponent(name + ".gpx")
        try GPX.write(Route(name: name, segments: [[pt(52, 4.9), pt(52.01, 4.91)]])).write(to: url)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    @Test func prefersOwnRoutesThenNewestAndSortsByName() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<10 { try add(root, "Own \(i)", age: Double(i) * 100) }
        for i in 0..<10 { try add(root, "Strava \(i)", strava: true, age: Double(i)) }
        try "not xml".write(to: RouteSync.folder(root: root).appendingPathComponent("broken.gpx"), atomically: true, encoding: .utf8)

        let sel = RouteSync.select(root: root)
        #expect(sel.chosen.count == 15)
        #expect(sel.chosen.filter { !$0.fromStrava }.count == 10)
        // The 5 newest Strava routes (smallest age) fit.
        #expect(Set(sel.chosen.filter(\.fromStrava).map(\.watchName)) == Set((0..<5).map { "Strava \($0)" }))
        #expect(sel.chosen.map(\.watchName) == sel.chosen.map(\.watchName).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(sel.skipped.count == 5)
        #expect(sel.failed.map(\.0.lastPathComponent) == ["broken.gpx"])
    }

    @Test func skipsDuplicatesKeepingTheOwnCopy() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try add(root, "Loop", age: 100)
        try add(root, "Loop", strava: true, age: 0)
        let sel = RouteSync.select(root: root)
        #expect(sel.chosen.count == 1 && sel.chosen[0].fromStrava == false)
        #expect(sel.duplicates.map(\.lastPathComponent) == ["Loop.gpx"])
    }

    @Test func plansKeepWriteAndDelete() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try add(root, "A", age: 0); try add(root, "B", age: 0)
        let sel = RouteSync.select(root: root)
        let onWatch: [UInt32: Route?] = [
            RouteFile.fileID(slot: 0): sel.chosen[0].stored,          // A: unchanged
            RouteFile.fileID(slot: 1): Route(name: "Old", segments: [[pt(1, 1)]]),
            RouteFile.fileID(slot: 2): Route(name: "Gone", segments: [[pt(2, 2)]]),
            RouteFile.fileID(slot: 3): Route?.none,                   // unreadable
        ]
        let steps = RouteSync.plan(sel, onWatch: onWatch).steps.map { step -> String in
            switch step {
            case .keep(let slot, let c): return "keep \(slot) \(c.watchName)"
            case .write(let slot, let c): return "write \(slot) \(c.watchName)"
            case .delete(let id, let name): return "delete \(id & 0xffff) \(name ?? "?")"
            }
        }
        #expect(steps == ["keep 0 A", "write 1 B", "delete 2 Gone", "delete 3 ?"])
    }
}

// MARK: - Strava routes

/// Serves canned Strava responses: the route list and each route's GPX.
final class FakeStrava: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routesJSON = "[]"
    nonisolated(unsafe) static var gpxRequests: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "www.strava.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url!.path
        var body = Data(), status = 200
        if path.hasSuffix("/routes") {
            body = Data(Self.routesJSON.utf8)
        } else if path.hasSuffix("/export_gpx") {
            let id = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            Self.gpxRequests.append(id)
            body = GPX.write(Route(name: "Route \(id)", segments: [[pt(52, 4.9), pt(52.01, 4.91)]]))
        } else { status = 404 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func route(_ id: String, _ name: String, type: Int, starred: Bool = true, created: String, updated: String? = nil) -> String {
    #"{"id": \#(id), "id_str": "\#(id)", "name": "\#(name)", "type": \#(type), "starred": \#(starred), "private": false, "created_at": "\#(created)", "updated_at": "\#(updated ?? created)"}"#
}

@Suite(.serialized) struct StravaRouteTests {
    @Test func decodesRouteList() throws {
        let json = "[" + [route("3344556677889900112", "Run", type: 2, created: "2024-01-02T10:00:00Z"),
                          route("2", "Hike", type: 4, starred: false, created: "2024-01-03T10:00:00.123Z"),
                          route("3", "Gravel", type: 6, created: "bad date")].joined(separator: ",") + "]"
        let r = try StravaRoute.decodeList(Data(json.utf8))
        #expect(r.map(\.id) == ["3344556677889900112", "2", "3"])
        #expect(r.map(\.kind) == [.run, .walk, .ride])
        #expect(r[0].starred && !r[1].starred)
        #expect(r[1].createdAt.timeIntervalSince1970 > 1_704_000_000)
        #expect(r[2].createdAt == .distantPast)
    }

    @Test func picksStarredRoutesOfChosenKindsNewestFirst() throws {
        let json = "[" + (0..<20).map { route("\($0 + 1)", "Run \($0)", type: $0 % 2 == 0 ? 2 : 5,
                                              created: String(format: "2024-01-%02dT10:00:00Z", $0 + 1)) }.joined(separator: ",")
            + "," + route("99", "Ride", type: 1, created: "2025-01-01T00:00:00Z")
            + "," + route("98", "Unstarred", type: 2, starred: false, created: "2025-01-01T00:00:00Z") + "]"
        let all = try StravaRoute.decodeList(Data(json.utf8))
        let w = StravaRouteSync.wanted(all, kinds: [.run])
        #expect(w.count == 15)
        #expect(w.first?.name == "Run 19")
        #expect(!w.contains { $0.name == "Ride" || $0.name == "Unstarred" })
        #expect(StravaRouteSync.wanted(all, kinds: []).isEmpty)
    }

    @Test func downloadsUpdatesAndRemovesRoutes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("strava-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeStrava.self]
        var creds = StravaCredentials(clientID: "1", clientSecret: "s")
        creds.accessToken = "t"; creds.refreshToken = "r"; creds.expiresAt = Date().addingTimeInterval(3600); creds.athleteID = 7
        let client = StravaClient(credentials: creds, session: URLSession(configuration: config))
        let dir = RouteSync.stravaFolder(root: root)
        func files() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".gpx") }.sorted() }
        // A file the user put there themselves is never touched.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try GPX.write(Route(name: "Mine", segments: [[pt(1, 1)]])).write(to: dir.appendingPathComponent("Mine.gpx"))

        FakeStrava.routesJSON = "[" + route("1", "Amstel/loop", type: 2, created: "2024-01-01T10:00:00Z") + ","
            + route("2", "Ride", type: 1, created: "2024-01-02T10:00:00Z") + "]"
        FakeStrava.gpxRequests = []
        var s = try await StravaRouteSync.sync(client: client, kinds: [.run], root: root, log: SyncLog { _ in })
        #expect(s.downloaded == ["Amstel/loop"])
        #expect(try files() == ["Amstel-loop.gpx", "Mine.gpx"])
        let created = try dir.appendingPathComponent("Amstel-loop.gpx").resourceValues(forKeys: [.creationDateKey]).creationDate
        #expect(created == ISO8601DateFormatter().date(from: "2024-01-01T10:00:00Z"))

        // Unchanged: no download.
        s = try await StravaRouteSync.sync(client: client, kinds: [.run], root: root, log: SyncLog { _ in })
        #expect(s.unchanged == 1 && FakeStrava.gpxRequests == ["1"])

        // Updated and renamed on Strava: downloaded again under the new name.
        FakeStrava.routesJSON = "[" + route("1", "Amstel", type: 2, created: "2024-01-01T10:00:00Z", updated: "2024-02-01T10:00:00Z") + "]"
        s = try await StravaRouteSync.sync(client: client, kinds: [.run], root: root, log: SyncLog { _ in })
        #expect(s.downloaded == ["Amstel"] && FakeStrava.gpxRequests == ["1", "1"])
        #expect(try files() == ["Amstel.gpx", "Mine.gpx"])

        // No kinds chosen: removed, without asking Strava for anything.
        FakeStrava.routesJSON = "not json"
        s = try await StravaRouteSync.sync(client: client, kinds: [], root: root, log: SyncLog { _ in })
        #expect(s.removed == ["Amstel.gpx"])
        #expect(try files() == ["Mine.gpx"])
    }

    @Test func storesSettings() throws {
        let d = try #require(UserDefaults(suiteName: "TomTomSyncTests-\(UUID().uuidString)"))
        #expect(RouteSettings.load(d).enabled && RouteSettings.load(d).stravaKinds == [.run])
        RouteSettings(enabled: false, stravaKinds: [.walk, .ride]).save(d)
        let s = RouteSettings.load(d)
        #expect(!s.enabled && s.stravaKinds == [.walk, .ride])
    }
}
