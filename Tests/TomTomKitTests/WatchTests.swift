import Foundation
import Testing
@testable import TomTomKit

private let quiet = SyncLog { _ in }

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tomtomsync-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func activityID(_ n: Int) -> UInt32 { FileID.ttbinType | UInt32(n) }

// MARK: - Protocol

@Suite struct WatchProtocolTests {
    @Test func runsTheStartupSequenceAndReadsDeviceInfo() throws {
        let fake = FakeWatch()
        let w = Watch(transport: fake)
        try w.startup()
        #expect(try w.productID() == fake.productID)
        #expect(try w.firmwareVersion() == "1.7.64")
        #expect(try abs(w.currentTime().timeIntervalSinceNow) < 5)
        w.close()
        #expect(fake.isClosed)
    }

    @Test func listsFilesSortedAndByType() throws {
        let fake = FakeWatch()
        fake.files = [activityID(1): [1], FileID.manifest: [2, 3], activityID(0): [4, 5, 6]]
        let w = Watch(transport: fake)
        #expect(try w.listFiles().map(\.id) == [FileID.manifest, activityID(0), activityID(1)])
        #expect(try w.listFiles(type: FileID.ttbinType) == [WatchFile(id: activityID(0), size: 3), WatchFile(id: activityID(1), size: 1)])
    }

    @Test func readsAndWritesFilesLargerThanOnePacket() throws {
        let fake = FakeWatch()
        let w = Watch(transport: fake)
        let data = (0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        var progress: [Int] = []
        w.progress = { done, _ in progress.append(done) }
        try w.writeVerified(0x0001_0100, data)
        #expect(fake.files[0x0001_0100] == data)
        #expect(try w.readFile(0x0001_0100) == data)
        #expect(progress.contains(1000) && progress.count > 4)
        // Writing again replaces the file.
        try w.writeVerified(0x0001_0100, [9, 9])
        #expect(fake.files[0x0001_0100] == [9, 9])
    }

    @Test func reportsAWriteTheWatchDidNotStore() {
        let fake = FakeWatch()
        fake.corruptsWrites = true
        #expect(throws: WatchError.self) { try Watch(transport: fake).writeVerified(0x0001_0100, [1, 2, 3]) }
    }

    @Test func failsCleanlyOnMissingFilesShortRepliesAndDisconnects() {
        let fake = FakeWatch()
        let w = Watch(transport: fake)
        #expect(throws: WatchError.self) { try w.readFile(activityID(0)) }
        #expect(throws: WatchError.self) { try w.deleteFile(activityID(0)) }
        // Replies that are too short for the value they should hold.
        fake.shortReplies = [0x20, 0x14, 0x05]
        fake.files[activityID(1)] = [1, 2, 3]
        #expect(throws: WatchError.self) { try w.productID() }
        #expect(throws: WatchError.self) { try w.currentTime() }
        #expect(throws: WatchError.self) { try w.readFile(activityID(1)) }
        fake.shortReplies = []
        fake.requestsUntilDisconnect = 2
        #expect(throws: TransportError.self) { try w.readFile(activityID(1)) }
    }
}

// MARK: - Export

@Suite struct WatchExportTests {
    @Test func storesBothFilesAndDeletesOnlyWhatIsSaved() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeWatch()
        let run = TTBinBuilder.run(), garbage = [UInt8](repeating: 7, count: 300)
        fake.files = [activityID(0): run, activityID(1): garbage, FileID.manifest: [1]]
        var failures: [String] = []
        let results = try Exporter.exportAll(watch: Watch(transport: fake), root: root, deleteAfterExport: true, log: quiet) {
            failures.append($0)
        }

        #expect(results.count == 2)
        #expect(results.map(\.deletedFromWatch) == [true, true])
        #expect(fake.deleted == [activityID(0), activityID(1)])
        #expect(fake.files.keys.sorted() == [FileID.manifest], "only activities are deleted")
        // The readable activity has a FIT file; the other keeps its raw file and is reported.
        #expect(try Data(contentsOf: results[0].ttbin) == Data(run))
        #expect(results[0].fit.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(results[0].ttbin.lastPathComponent == "2026-04-01_100000_running.ttbin")
        #expect(try Data(contentsOf: results[1].ttbin) == Data(garbage))
        #expect(results[1].fit == nil)
        #expect(failures.count == 1 && failures[0].contains("could not be converted"))
        let mode = try FileManager.default.attributesOfItem(atPath: results[0].ttbin.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func keepsActivitiesOnTheWatchWhenDeleteIsOffAndDoesNotDuplicate() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeWatch()
        fake.files = [activityID(0): TTBinBuilder.run()]
        let w = Watch(transport: fake)
        for _ in 0..<2 { _ = try Exporter.exportAll(watch: w, root: root, deleteAfterExport: false, log: quiet) }
        #expect(fake.deleted.isEmpty && fake.files.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("ttbin").path).count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("fit").path).count == 1)
    }

    @Test func skipsAnUnreadableActivityAndStopsAfterTwoInARow() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeWatch()
        let run = TTBinBuilder.run()
        // A trailing "ready" status record makes each activity different without changing what it holds.
        for i in 0..<5 { fake.files[activityID(i)] = run + [0x21, 0, UInt8(i), 0, 0, 0, 0] }
        fake.unreadable = [activityID(0), activityID(2), activityID(3)]
        var failures: [String] = []
        let results = try Exporter.exportAll(watch: Watch(transport: fake), root: root, deleteAfterExport: true, log: quiet) {
            failures.append($0)
        }
        // 0 fails, 1 is exported, 2 and 3 fail in a row, 4 is never tried.
        #expect(results.count == 1)
        #expect(fake.deleted == [activityID(1)])
        #expect(fake.files.keys.sorted() == [0, 2, 3, 4].map(activityID))
        #expect(failures.count == 4)
        #expect(failures.last == "Export stopped; 1 more activity left on the watch")
    }

    @Test func reportsAnActivityThatCannotBeDeletedButKeepsTheExport() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeWatch()
        fake.files = [activityID(0): TTBinBuilder.run()]
        fake.undeletable = [activityID(0)]
        var failures: [String] = []
        let results = try Exporter.exportAll(watch: Watch(transport: fake), root: root, deleteAfterExport: true, log: quiet) {
            failures.append($0)
        }
        #expect(results.count == 1 && !results[0].deletedFromWatch && results[0].fit != nil)
        #expect(failures.count == 1 && failures[0].contains("could not be deleted"))
    }
}

// MARK: - Time zone

@Suite struct WatchTimeSyncTests {
    private func manifest(offset: Int) -> [UInt8] {
        var d = [UInt8]()
        d.appendLE(UInt16(0x0085)); d.appendLE(UInt16(3))
        for (index, value) in [(UInt16(1), UInt32(42)), (WatchSettings.utcOffsetIndex, UInt32(bitPattern: Int32(offset))), (UInt16(300), UInt32(7))] {
            d.appendLE(index); d.appendLE(value)
        }
        return d
    }

    @Test func writesTheOffsetOnlyWhenItDiffersAndLeavesOtherSettingsAlone() throws {
        let fake = FakeWatch()
        let mac = TimeZone.current.secondsFromGMT()
        fake.files[FileID.manifest] = manifest(offset: mac + 3600)
        let w = Watch(transport: fake)
        #expect(try TimeSync.sync(watch: w, log: quiet))
        #expect(fake.files[FileID.manifest] == manifest(offset: mac))
        #expect(fake.written == [FileID.manifest])
        #expect(try !TimeSync.sync(watch: w, log: quiet))
        #expect(fake.written == [FileID.manifest], "no second write")
    }

    @Test func refusesASettingsFileItDoesNotUnderstand() {
        let fake = FakeWatch()
        fake.files[FileID.manifest] = [0x85, 0x00, 0x09, 0x00, 1, 2, 3]   // says 9 entries, holds none
        #expect(throws: WatchError.self) { try TimeSync.sync(watch: Watch(transport: fake), log: quiet) }
        #expect(fake.written.isEmpty)
        // No utc_offset entry: nothing to set, so nothing is written.
        var d = [UInt8](); d.appendLE(UInt16(0x0085)); d.appendLE(UInt16(1)); d.appendLE(UInt16(1)); d.appendLE(UInt32(42))
        fake.files[FileID.manifest] = d
        #expect(throws: WatchError.self) { try TimeSync.sync(watch: Watch(transport: fake), log: quiet) }
        #expect(fake.written.isEmpty)
    }
}

// MARK: - Routes

@Suite struct WatchRouteSyncTests {
    private func route(_ name: String, _ lat: Double) -> Route {
        Route(name: name, segments: [[Route.Point(latitude: lat, longitude: 4.9), Route.Point(latitude: lat + 0.01, longitude: 4.91)]])
    }
    private func addGPX(_ root: URL, _ r: Route) throws {
        let dir = RouteSync.folder(root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try GPX.write(r).write(to: dir.appendingPathComponent(r.name + ".gpx"))
    }
    private func names(_ fake: FakeWatch) -> [String] {
        fake.files.keys.sorted().map { (try? RouteFile.decode(fake.files[$0]!))?.name ?? "?" }
    }

    @Test func firstSyncSavesTheWatchRoutesThenMirrorsTheFolder() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeWatch()
        let old = route("Old", 51)
        fake.files[RouteFile.fileID(slot: 0)] = RouteFile.encode(old, name: "Old")
        try addGPX(root, route("Amstel", 52))
        let w = Watch(transport: fake)

        let first = try RouteSync.sync(watch: w, root: root, log: quiet)
        #expect(first.imported.map(\.lastPathComponent) == ["Old.gpx"])
        #expect(first.onWatch == ["Amstel", "Old"])
        #expect(names(fake) == ["Amstel", "Old"], "sorted by name, in slots 0 and 1")
        let dir = RouteSync.folder(root: root)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".watch-backup-AB1234C56789/0x00b80000.bin").path))

        // Nothing to do the second time.
        let again = try RouteSync.sync(watch: w, root: root, log: quiet)
        #expect(again.written == 0 && again.deleted == 0 && again.imported.isEmpty)

        // Removing a file removes the route from the watch.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Amstel.gpx"))
        let after = try RouteSync.sync(watch: w, root: root, log: quiet)
        #expect(after.onWatch == ["Old"] && after.deleted == 1)
        #expect(names(fake) == ["Old"])
    }

    @Test func dryRunChangesNothing() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeWatch()
        fake.files[RouteFile.fileID(slot: 0)] = RouteFile.encode(route("Old", 51), name: "Old")
        try addGPX(root, route("Amstel", 52))
        let s = try RouteSync.sync(watch: Watch(transport: fake), root: root, dryRun: true, log: quiet)
        #expect(s.onWatch == ["Amstel", "Old"])
        #expect(fake.written.isEmpty && fake.deleted.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: RouteSync.folder(root: root).path) == ["Amstel.gpx"])
    }

    @Test func leavesTheWatchAloneWhenARouteOnItCannotBeRead() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeWatch()
        fake.files[RouteFile.fileID(slot: 0)] = RouteFile.encode(route("Old", 51), name: "Old")
        fake.files[RouteFile.fileID(slot: 1)] = [1, 2, 3, 4]
        try addGPX(root, route("Amstel", 52))
        #expect(throws: RouteSync.SyncError.self) { try RouteSync.sync(watch: Watch(transport: fake), root: root, log: quiet) }
        #expect(fake.written.isEmpty && fake.deleted.isEmpty)
    }

    @Test func leavesTheWatchAloneWhenAFileInTheFolderCannotBeRead() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeWatch()
        fake.files[RouteFile.fileID(slot: 0)] = RouteFile.encode(route("Old", 51), name: "Old")
        try addGPX(root, route("Amstel", 52))
        try "not xml".write(to: RouteSync.folder(root: root).appendingPathComponent("broken.gpx"), atomically: true, encoding: .utf8)
        #expect(throws: RouteSync.SyncError.self) { try RouteSync.sync(watch: Watch(transport: fake), root: root, log: quiet) }
        #expect(fake.written.isEmpty && fake.deleted.isEmpty)
    }

    @Test func writesNothingToAWatchWithoutRouteSupport() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeWatch()
        fake.productID = 0x07d5
        try addGPX(root, route("Amstel", 52))
        let s = try RouteSync.sync(watch: Watch(transport: fake), root: root, log: quiet)
        #expect(!s.supported)
        #expect(fake.written.isEmpty && fake.files.isEmpty)
    }
}

// MARK: - Strava upload queue

@Suite struct StravaUploadQueueTests {
    private struct Offline: Error {}

    /// A root with FIT files (no ttbin, so they have no metadata and count as worth uploading).
    private func root(with fits: [String]) throws -> URL {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("fit")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in fits { try Data([1, 2, 3]).write(to: dir.appendingPathComponent(f)) }
        return root
    }
    private func fits(_ root: URL, _ names: [String]) -> [URL] { names.map { root.appendingPathComponent("fit/\($0)") } }

    @Test func uploadsRecordsAndClearsTheList() async throws {
        let root = try root(with: ["a.fit", "b.fit"])
        defer { try? FileManager.default.removeItem(at: root) }
        var s = SyncSummary()
        await StravaUploadQueue.run(newlyExported: fits(root, ["a.fit", "b.fit"]), root: root, log: quiet, summary: &s) { fit, _ in
            fit.lastPathComponent == "a.fit" ? .created(activityID: 11) : .duplicate(activityID: nil)
        }
        #expect(s.uploaded.map(\.0.lastPathComponent) == ["a.fit", "b.fit"] && s.warnings.isEmpty)
        let ledger = StravaLedger(root: root)
        #expect(ledger.activityID(fits(root, ["a.fit"])[0]) == 11)
        #expect(ledger.contains(fits(root, ["b.fit"])[0]))
        #expect(PendingUploads(root: root).files.isEmpty)
    }

    @Test func keepsWhatCouldNotBeUploadedForTheNextSync() async throws {
        let root = try root(with: ["a.fit", "b.fit", "c.fit"])
        defer { try? FileManager.default.removeItem(at: root) }
        var s = SyncSummary()
        var attempts: [String] = []
        await StravaUploadQueue.run(newlyExported: fits(root, ["a.fit", "b.fit", "c.fit"]), root: root, log: quiet, summary: &s) { fit, _ in
            attempts.append(fit.lastPathComponent)
            if fit.lastPathComponent == "b.fit" { throw Offline() }
            return .created(activityID: 1)
        }
        // Stops at the first failure that isn't about one file: the rest would fail too.
        #expect(attempts == ["a.fit", "b.fit"])
        #expect(s.uploaded.count == 1)
        #expect(s.warnings.count == 1 && s.warnings[0].contains("2 activities will be tried again"))
        #expect(PendingUploads(root: root).files == ["b.fit", "c.fit"])

        // The next sync has nothing new but finishes the list.
        var next = SyncSummary()
        await StravaUploadQueue.run(newlyExported: [], root: root, log: quiet, summary: &next) { _, _ in .created(activityID: 2) }
        #expect(next.uploaded.map(\.0.lastPathComponent) == ["b.fit", "c.fit"] && next.warnings.isEmpty)
        #expect(PendingUploads(root: root).files.isEmpty)
    }

    @Test func dropsAFileStravaRefusesAndGoesOn() async throws {
        let root = try root(with: ["a.fit", "b.fit"])
        defer { try? FileManager.default.removeItem(at: root) }
        var s = SyncSummary()
        await StravaUploadQueue.run(newlyExported: fits(root, ["a.fit", "b.fit"]), root: root, log: quiet, summary: &s) { fit, _ in
            if fit.lastPathComponent == "a.fit" { throw StravaError.uploadFailed("bad file") }
            return .created(activityID: 3)
        }
        #expect(s.uploaded.map(\.0.lastPathComponent) == ["b.fit"])
        #expect(s.warnings == ["Strava refused a.fit: bad file"])
        #expect(PendingUploads(root: root).files.isEmpty)
        #expect(!StravaLedger(root: root).contains(fits(root, ["a.fit"])[0]))
    }

    @Test func skipsFilesAlreadyUploadedOrGone() async throws {
        let root = try root(with: ["a.fit"])
        defer { try? FileManager.default.removeItem(at: root) }
        var ledger = StravaLedger(root: root)
        try ledger.record(fits(root, ["a.fit"])[0], activityID: 5)
        var s = SyncSummary()
        var calls = 0
        await StravaUploadQueue.run(newlyExported: fits(root, ["a.fit", "gone.fit"]), root: root, log: quiet, summary: &s) { _, _ in
            calls += 1
            return .created(activityID: 9)
        }
        #expect(calls == 0 && s.uploaded.isEmpty && s.warnings.isEmpty)
        #expect(PendingUploads(root: root).files.isEmpty)
    }
}

// MARK: - Strava upload over HTTP

/// Answers Strava's upload endpoint with a canned status and body.
final class FakeStravaUploads: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 201
    nonisolated(unsafe) static var body = "{}"
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "www.strava.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.append(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct StravaUploadTests {
    private func upload(status: Int, body: String) async throws -> StravaUploadResult {
        let fit = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).fit")
        try Data([1, 2, 3]).write(to: fit)
        defer { try? FileManager.default.removeItem(at: fit) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeStravaUploads.self]
        // A token that is still valid, so nothing is refreshed or saved.
        var creds = StravaCredentials(clientID: "1", clientSecret: "s")
        creds.accessToken = "t"; creds.refreshToken = "r"; creds.expiresAt = Date().addingTimeInterval(3600)
        FakeStravaUploads.status = status; FakeStravaUploads.body = body; FakeStravaUploads.requests = []
        return try await StravaClient(credentials: creds, session: URLSession(configuration: config)).upload(fit: fit, description: "note")
    }

    @Test func returnsTheActivityOnceStravaHasProcessedIt() async throws {
        let r = try await upload(status: 201, body: #"{"id": 5, "activity_id": 77, "error": null}"#)
        #expect(r.activityID == 77)
        let req = try #require(FakeStravaUploads.requests.first)
        #expect(req.httpMethod == "POST" && req.url?.path == "/api/v3/uploads")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer t")
    }

    @Test func treatsADuplicateAsAlreadyUploaded() async throws {
        let r = try await upload(status: 201, body: #"{"id": 5, "error": "x.fit duplicate of <a href='/activities/1234'>Run</a>"}"#)
        guard case .duplicate(let id) = r else { Issue.record("expected a duplicate"); return }
        #expect(id == 1234)
    }

    @Test func tellsARefusedFileFromARateLimit() async {
        // A refused file is dropped from the queue; a rate limit is retried later.
        await #expect(throws: StravaError.self) { try await upload(status: 201, body: #"{"id": 5, "error": "The file is empty"}"#) }
        do {
            _ = try await upload(status: 429, body: #"{"message": "Rate Limit Exceeded"}"#)
            Issue.record("expected an error")
        } catch StravaError.http(let code, _) {
            #expect(code == 429)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
