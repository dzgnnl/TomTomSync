import Foundation
import Testing
@testable import TomTomKit

/// Builds a synthetic ttbin: a 10-minute run with GPS, heart rate, one lap,
/// a pause and a heart rate recovery record. No real recordings in the repo.
private enum TTBinBuilder {
    static let start = 1_775_030_400   // 2026-04-01 08:00 UTC
    static let localOffset: Int32 = 7200
    static let seconds = 600

    static func run() -> [UInt8] {
        var d: [UInt8] = [0x20]
        d.appendLE(UInt16(10))                                            // file version
        for v: UInt16 in [1, 7, 64] { d.appendLE(v) }                     // firmware
        d.appendLE(UInt16(2005))                                          // product ID
        d.appendLE(UInt32(start + Int(localOffset)))                     // local start time
        d += [UInt8](repeating: 0, count: 16 + 80)
        d.appendLE(UInt32(start + Int(localOffset)))                     // watch time
        d.appendLE(UInt32(bitPattern: localOffset))
        d.append(0)
        let lengths: [(UInt8, UInt16)] = [(0x21, 7), (0x22, 29), (0x25, 7), (0x27, 12), (0x2f, 11), (0x3f, 9), (0x4a, 9)]
        d.append(UInt8(lengths.count))
        for (tag, len) in lengths { d.append(tag); d.appendLE(len) }

        func local(_ t: Int) -> UInt32 { UInt32(start + t + Int(localOffset)) }
        func status(_ s: UInt8, _ t: Int) { d += [0x21, s, 0]; d.appendLE(local(t)) }

        status(1, 0)
        for i in 0..<seconds {
            d.append(0x22)
            d.appendLE(UInt32(bitPattern: Int32(523_700_000 + i * 100)))   // lat 52.37
            d.appendLE(UInt32(bitPattern: Int32(49_000_000)))              // lon 4.9
            d.appendLE(UInt16(0)); d.appendLE(UInt16(300))                  // heading, speed cm/s
            d.appendLE(UInt32(start + i))                                   // UTC
            d.appendLE(UInt16(i / 6))                                       // calories
            d.appendLE(Float(3).bitPattern)                                 // instant speed
            d.appendLE(Float(3 * i).bitPattern)                             // cumulative distance
            d += [i % 2 == 0 ? 2 : 3, 0]                                    // steps (150 spm), unused
            d += [0x25, UInt8(120 + i % 30), 0]; d.appendLE(local(i))
            if i == 300 { d.append(0x2f); d.appendLE(UInt32(300)); d.appendLE(Float(900).bitPattern); d.appendLE(UInt16(50)) }
        }
        status(2, seconds)
        d.append(0x3f); d.appendLE(UInt32(2)); d.appendLE(UInt32(24))      // HR recovery: score 2, −24 bpm
        d.append(0x27); d.append(0); d.appendLE(Float(1800).bitPattern); d.appendLE(UInt32(seconds)); d.appendLE(UInt16(100))
        return d
    }
}

@Suite struct TTBinTests {
    @Test func parsesRun() throws {
        let a = try TTBinParser.parse(TTBinBuilder.run())
        #expect(a.productID == 2005)
        #expect(a.firmware == "1.7.64")
        #expect(a.localOffset == 7200)
        #expect(a.sport == .running)
        #expect(a.startTime == Date(timeIntervalSince1970: TimeInterval(TTBinBuilder.start)))
        #expect(a.points.count == TTBinBuilder.seconds)
        #expect(zip(a.points, a.points.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(a.points.allSatisfy { $0.heartRate != nil && $0.latitude != nil })
        #expect(abs(a.points[0].latitude! - 52.37) < 1e-9)
        #expect(a.laps.count == 1)
        #expect(a.timerTime == TimeInterval(TTBinBuilder.seconds))
        #expect(a.summaryDistance == 1800)
        #expect(a.hrRecovery?.drop == 24)
    }

    @Test func derivesCadenceAndDescription() throws {
        let a = try TTBinParser.parse(TTBinBuilder.run())
        #expect(abs((a.averageCadence ?? 0) - 150) < 1)
        #expect(a.stravaDescription == "Heart rate recovery: −24 bpm in 1 min")
    }

    @Test func rejectsGarbage() {
        #expect(throws: TTBinError.self) { try TTBinParser.parse([UInt8](repeating: 0, count: 200)) }
    }

    /// Truncated or corrupted files (e.g. a watch reset mid-write) must throw or
    /// parse partially, never crash.
    @Test func survivesCorruptInput() {
        let good = TTBinBuilder.run()
        for cut in stride(from: 0, to: good.count, by: 97) { _ = try? TTBinParser.parse(Array(good[..<cut])) }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var bad = good
            for _ in 0..<8 { bad[Int.random(in: 0..<bad.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            if let a = try? TTBinParser.parse(bad) { _ = ActivityFIT.encode(a) }
        }
    }
}

@Suite struct FITTests {
    @Test func crcAndHeader() throws {
        #expect(FITWriter.crc([]) == 0)
        let file = ActivityFIT.encode(try TTBinParser.parse(TTBinBuilder.run()))
        #expect(FITWriter.crc(file) == 0, "CRC over whole file including trailing CRC must be 0")
        #expect(Array(file[8..<12]) == Array(".FIT".utf8))
        #expect(Int(file.u32le(4)) == file.count - 14 - 2)
    }
}

@Suite struct SettingsTests {
    @Test func roundTripsAndEditsUTCOffset() throws {
        var raw: [UInt8] = []
        raw.appendLE(UInt16(0x0085)); raw.appendLE(UInt16(3))
        for (i, v) in [(UInt16(1), UInt32(7)), (169, 3600), (200, 0xffff_ffff)] { raw.appendLE(i); raw.appendLE(v) }
        var s = try WatchSettings(data: raw)
        #expect(s.data == raw)
        #expect(s.utcOffset == 3600)
        let changed = s.setUTCOffset(-3600)
        #expect(changed)
        #expect(try WatchSettings(data: s.data).utcOffset == -3600)
        #expect(throws: WatchError.self) { try WatchSettings(data: Array(raw.dropLast())) }
    }
}

@Suite struct StravaTests {
    @Test func interpretsUploadStatus() throws {
        #expect(try StravaClient.interpret(["status": "Your activity is still being processed."]) == nil)
        #expect(try StravaClient.interpret(["activity_id": Int64(42)])?.activityID == 42)
        let dup = try StravaClient.interpret(["error": "x.fit duplicate of <a href='/activities/123456' target='_blank'>Morning Run</a>"])
        #expect(dup?.activityID == 123456)
        #expect(throws: StravaError.self) { try StravaClient.interpret(["error": "Improperly formatted data."]) }
    }

    @Test func authorizeURLCarriesState() throws {
        let url = StravaClient(credentials: StravaCredentials(clientID: "1", clientSecret: "x")).authorizeURL(state: "abc")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains { $0.name == "state" && $0.value == "abc" })
        #expect(!items.contains { $0.name == "client_secret" })
    }
}

@Suite struct ExportTests {
    @Test func reusesNameForSameActivityAndAvoidsOverwritingOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ttbin = root.appendingPathComponent("ttbin"), fit = root.appendingPathComponent("fit")
        try FileManager.default.createDirectory(at: ttbin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fit, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let a: [UInt8] = [1, 2, 3], b: [UInt8] = [4, 5, 6]
        func name(_ d: [UInt8], _ id: UInt32) -> String {
            Exporter.availableBaseName("run", for: d, fileID: id, ttbinDir: ttbin, fitDir: fit)
        }
        #expect(name(a, 0x0091_0000) == "run")
        try Data(a).write(to: ttbin.appendingPathComponent("run.ttbin"))
        #expect(name(a, 0x0091_0000) == "run", "re-export of the same activity keeps its name")
        let other = name(b, 0x0091_0001)
        #expect(other != "run")
        try Data(b).write(to: ttbin.appendingPathComponent(other + ".ttbin"))
        #expect(name(b, 0x0091_0001) == other)
    }
}
