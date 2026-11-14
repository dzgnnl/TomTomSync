import Foundation

/// Little/big-endian helpers. The USB protocol is big-endian; ttbin and the
/// settings manifest are little-endian.
extension Array where Element == UInt8 {
    func u16le(_ o: Int) -> UInt16 { UInt16(self[o]) | UInt16(self[o + 1]) << 8 }
    func u32le(_ o: Int) -> UInt32 {
        UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }
    func i32le(_ o: Int) -> Int32 { Int32(bitPattern: u32le(o)) }
    func f32le(_ o: Int) -> Float { Float(bitPattern: u32le(o)) }

    func u32be(_ o: Int) -> UInt32 {
        UInt32(self[o]) << 24 | UInt32(self[o + 1]) << 16 | UInt32(self[o + 2]) << 8 | UInt32(self[o + 3])
    }

    mutating func appendBE(_ v: UInt32) {
        append(UInt8(v >> 24 & 0xff)); append(UInt8(v >> 16 & 0xff))
        append(UInt8(v >> 8 & 0xff)); append(UInt8(v & 0xff))
    }
    mutating func appendLE(_ v: UInt16) { append(UInt8(v & 0xff)); append(UInt8(v >> 8)) }
    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xff)); append(UInt8(v >> 8 & 0xff))
        append(UInt8(v >> 16 & 0xff)); append(UInt8(v >> 24 & 0xff))
    }

}

extension UInt32 {
    public var hex: String { String(format: "0x%08x", self) }
}
