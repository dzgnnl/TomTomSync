import Foundation

/// Minimal protobuf (proto2 wire format) encoder and decoder: just enough for
/// the watch's route files. No schema; callers build and read fields by number.
struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, wireType: 0); appendVarint(value)
    }

    mutating func int32(_ field: Int, _ value: Int32) {
        // Negative int32 values are sign-extended to 64 bits on the wire.
        varint(field, UInt64(bitPattern: Int64(value)))
    }

    mutating func fixed32(_ field: Int, _ value: UInt32) {
        key(field, wireType: 5); bytes.appendLE(value)
    }

    mutating func data(_ field: Int, _ value: [UInt8]) {
        key(field, wireType: 2); appendVarint(UInt64(value.count)); bytes += value
    }

    mutating func string(_ field: Int, _ value: String) { data(field, Array(value.utf8)) }

    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var m = ProtoWriter(); build(&m); data(field, m.bytes)
    }

    private mutating func key(_ field: Int, wireType: UInt64) { appendVarint(UInt64(field) << 3 | wireType) }

    private mutating func appendVarint(_ v: UInt64) {
        var v = v
        while v >= 0x80 { bytes.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        bytes.append(UInt8(v))
    }
}

enum ProtoError: Error { case truncated, badWireType(UInt8), badVarint }

/// One decoded field. Length-delimited values keep their raw bytes so callers
/// can decode them as a nested message or a string.
struct ProtoField {
    enum Value { case varint(UInt64), fixed32(UInt32), fixed64(UInt64), bytes([UInt8]) }
    var number: Int
    var value: Value

    var uint64: UInt64? { if case .varint(let v) = value { v } else { nil } }
    var uint32: UInt32? { if case .fixed32(let v) = value { v } else { nil } }
    var bytes: [UInt8]? { if case .bytes(let v) = value { v } else { nil } }
    var string: String? { bytes.map { String(decoding: $0, as: UTF8.self) } }
    func message() throws -> [ProtoField] { try ProtoReader.fields(bytes ?? []) }
}

enum ProtoReader {
    static func fields(_ d: [UInt8]) throws -> [ProtoField] {
        var out: [ProtoField] = []
        var p = 0
        func varint() throws -> UInt64 {
            var v: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard p < d.count else { throw ProtoError.truncated }
                guard shift < 64 else { throw ProtoError.badVarint }
                let b = d[p]; p += 1
                v |= UInt64(b & 0x7f) << shift
                if b < 0x80 { return v }
                shift += 7
            }
        }
        while p < d.count {
            let key = try varint()
            let number = Int(truncatingIfNeeded: key >> 3)
            switch UInt8(key & 7) {
            case 0: out.append(ProtoField(number: number, value: .varint(try varint())))
            case 1:
                guard p + 8 <= d.count else { throw ProtoError.truncated }
                let v = UInt64(d.u32le(p)) | UInt64(d.u32le(p + 4)) << 32; p += 8
                out.append(ProtoField(number: number, value: .fixed64(v)))
            case 2:
                let n = try varint()
                guard n <= UInt64(d.count - p) else { throw ProtoError.truncated }
                out.append(ProtoField(number: number, value: .bytes(Array(d[p..<(p + Int(n))])))); p += Int(n)
            case 5:
                guard p + 4 <= d.count else { throw ProtoError.truncated }
                out.append(ProtoField(number: number, value: .fixed32(d.u32le(p)))); p += 4
            case let t: throw ProtoError.badWireType(t)
            }
        }
        return out
    }
}

extension Array where Element == ProtoField {
    func first(_ number: Int) -> ProtoField? { first { $0.number == number } }
    func all(_ number: Int) -> [ProtoField] { filter { $0.number == number } }
}
