import Foundation

/// Minimal FIT file encoder (FIT protocol 2.0, little-endian).
///
/// Each message type gets one local definition; a data message's field values
/// are given in definition order. Use `nil` for "invalid" (the base type's
/// invalid value is written).
struct FITWriter {
    enum BaseType: UInt8 {
        case enumType = 0x00, uint8 = 0x02, uint16 = 0x84, sint32 = 0x85, uint32 = 0x86, uint32z = 0x8c

        var size: Int {
            switch self {
            case .enumType, .uint8: return 1
            case .uint16: return 2
            case .sint32, .uint32, .uint32z: return 4
            }
        }

        var invalid: UInt64 {
            switch self {
            case .enumType, .uint8: return 0xff
            case .uint16: return 0xffff
            case .sint32: return 0x7fff_ffff
            case .uint32: return 0xffff_ffff
            case .uint32z: return 0
            }
        }
    }

    struct Field {
        let number: UInt8
        let type: BaseType
    }

    struct Definition {
        let global: UInt16
        let fields: [Field]
    }

    /// Seconds between the Unix epoch and the FIT epoch (1989-12-31T00:00:00Z).
    static let epochOffset: TimeInterval = 631_065_600

    static func timestamp(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 - epochOffset) }

    private var body: [UInt8] = []
    private var locals: [UInt16: UInt8] = [:]   // global message number -> local type
    private var definitions: [UInt16: Definition] = [:]

    mutating func define(_ def: Definition) {
        precondition(locals.count < 16 || locals[def.global] != nil)
        let local = locals[def.global] ?? UInt8(locals.count)
        locals[def.global] = local
        definitions[def.global] = def
        body.append(0x40 | local)
        body.append(0)                         // reserved
        body.append(0)                         // little-endian
        body.appendLE(def.global)
        body.append(UInt8(def.fields.count))
        for f in def.fields { body += [f.number, UInt8(f.type.size), f.type.rawValue] }
    }

    mutating func write(_ global: UInt16, _ values: [Int64?]) {
        guard let def = definitions[global], let local = locals[global] else {
            preconditionFailure("message \(global) not defined")
        }
        precondition(values.count == def.fields.count)
        body.append(local)
        for (f, v) in zip(def.fields, values) {
            let raw = v.map { UInt64(bitPattern: $0) } ?? f.type.invalid
            for i in 0..<f.type.size { body.append(UInt8(truncatingIfNeeded: raw >> (8 * UInt64(i)))) }
        }
    }

    func finish() -> [UInt8] {
        var header: [UInt8] = [14, 0x20]
        header.appendLE(UInt16(21_158))        // profile version 21.158
        header.appendLE(UInt32(body.count))
        header += Array(".FIT".utf8)
        header.appendLE(Self.crc(header))
        var file = header + body
        file.appendLE(Self.crc(file))
        return file
    }

    static func crc(_ bytes: [UInt8]) -> UInt16 {
        let table: [UInt16] = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
                               0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]
        var crc: UInt16 = 0
        for b in bytes {
            var tmp = table[Int(crc & 0xf)]
            crc = (crc >> 4) & 0x0fff
            crc = crc ^ tmp ^ table[Int(b & 0xf)]
            tmp = table[Int(crc & 0xf)]
            crc = (crc >> 4) & 0x0fff
            crc = crc ^ tmp ^ table[Int((b >> 4) & 0xf)]
        }
        return crc
    }
}
