import Foundation
import Testing
@testable import TomTomKit

private func fixture(_ name: String) throws -> [UInt8] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
    return [UInt8](try Data(contentsOf: url))
}

@Suite struct TTBinTests {
    @Test func parsesGPSActivity() throws {
        let a = try TTBinParser.parse(fixture("test.ttbin"))
        #expect(a.localOffset == 7200)
        #expect(a.hasGPS)
        #expect(a.points.count > 4000)
        #expect(a.summaryDistance ?? 0 > 0)
        #expect(zip(a.points, a.points.dropFirst()).allSatisfy { $0.time < $1.time })
        let first = try #require(a.points.first { $0.latitude != nil })
        #expect(abs(first.latitude!) <= 90 && abs(first.longitude!) <= 180)
    }

    @Test func parsesHeartRate() throws {
        let a = try TTBinParser.parse(fixture("test_cycles.ttbin"))
        #expect(a.localOffset == -10800)
        let hr = a.points.compactMap(\.heartRate)
        #expect(hr.count > 600)
        #expect(hr.allSatisfy { $0 > 30 && $0 < 230 })
    }

    @Test func rejectsGarbage() {
        #expect(throws: TTBinError.self) { try TTBinParser.parse([UInt8](repeating: 0, count: 200)) }
    }
}

@Suite struct FITTests {
    @Test func crcMatchesReference() {
        // CRC of an empty FIT header from the FIT SDK examples.
        #expect(FITWriter.crc([]) == 0)
        let file = ActivityFIT.encode(try! TTBinParser.parse(fixture("test_cycles.ttbin")))
        #expect(FITWriter.crc(file) == 0, "CRC over whole file including trailing CRC must be 0")
        #expect(Array(file[8..<12]) == Array(".FIT".utf8))
        #expect(Int(file.u32le(4)) == file.count - 14 - 2)
    }
}

@Suite struct SettingsTests {
    @Test func roundTripsAndEditsUTCOffset() throws {
        let raw = try fixture("0x00850000.bin")
        var s = try WatchSettings(data: raw)
        #expect(s.data == raw)
        #expect(s.utcOffset != nil)
        let changed = s.setUTCOffset(-3600)
        #expect(changed)
        #expect(s.utcOffset == -3600)
        #expect(try WatchSettings(data: s.data).utcOffset == -3600)
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
}
