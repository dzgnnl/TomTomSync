import Foundation

/// The settings manifest file (0x00850000).
///
/// Layout (little-endian): u16 file type (0x0085), u16 entry count, then
/// `count` entries of { u16 index, u32 value }.
public struct WatchSettings: Equatable {
    /// Seconds east of UTC. Same index in every known firmware version.
    public static let utcOffsetIndex: UInt16 = 169

    public private(set) var entries: [(index: UInt16, value: UInt32)]
    private let fileType: UInt16

    public init(data: [UInt8]) throws {
        guard data.count >= 4 else { throw WatchError.badResponse("settings file too short") }
        fileType = data.u16le(0)
        let count = Int(data.u16le(2))
        guard data.count == 4 + count * 6 else {
            throw WatchError.badResponse("settings file size \(data.count) does not match \(count) entries")
        }
        entries = (0..<count).map { i in (data.u16le(4 + i * 6), data.u32le(6 + i * 6)) }
    }

    public func value(_ index: UInt16) -> UInt32? { entries.first { $0.index == index }?.value }

    public mutating func set(_ index: UInt16, _ value: UInt32) -> Bool {
        guard let i = entries.firstIndex(where: { $0.index == index }) else { return false }
        entries[i].value = value
        return true
    }

    public var utcOffset: Int? { value(Self.utcOffsetIndex).map { Int(Int32(bitPattern: $0)) } }

    public mutating func setUTCOffset(_ seconds: Int) -> Bool {
        set(Self.utcOffsetIndex, UInt32(bitPattern: Int32(seconds)))
    }

    public var data: [UInt8] {
        var d = [UInt8]()
        d.appendLE(fileType)
        d.appendLE(UInt16(entries.count))
        for e in entries { d.appendLE(e.index); d.appendLE(e.value) }
        return d
    }

    public static func == (a: WatchSettings, b: WatchSettings) -> Bool { a.data == b.data }
}
