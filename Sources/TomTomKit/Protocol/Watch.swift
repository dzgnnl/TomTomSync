import Foundation

public enum WatchError: Error, CustomStringConvertible {
    case badResponse(String)
    case fileError(op: String, fileID: UInt32, code: UInt32)
    case verifyFailed(UInt32)

    public var description: String {
        switch self {
        case .badResponse(let s): return "Unexpected response from watch: \(s)"
        case .fileError(let op, let id, let code): return "\(op) failed for file \(id.hex) (watch error \(code))"
        case .verifyFailed(let id): return "Verification of file \(id.hex) failed after writing"
        }
    }
}

/// File IDs and file-type prefixes on the watch. The upper 16 bits of a file
/// ID encode its type; the lower 16 bits are an index.
public enum FileID {
    public static let gpsQuickFix: UInt32 = 0x0001_0100
    public static let manifest: UInt32 = 0x0085_0000      // watch settings, incl. utc_offset
    public static let preferencesXML: UInt32 = 0x00f2_0000
    public static let typeMask: UInt32 = 0xffff_0000

    public static let ttbinType: UInt32 = 0x0091_0000      // recorded activities
    public static let historyType: UInt32 = 0x0073_0000
    public static let historySummaryType: UInt32 = 0x0083_0000
    public static let trackedActivityType: UInt32 = 0x00b1_0000
}

public struct WatchFile: Sendable, Hashable {
    public let id: UInt32
    public let size: Int
}

/// Request/response protocol on top of the HID transport.
///
/// Packet layout (both directions):
///   [0] 0x09 for requests, 0x01 for responses
///   [1] payload length + 2
///   [2] message counter (echoed in the response)
///   [3] message type
///   [4...] payload; integers are big-endian
public final class Watch {
    enum Msg: UInt8 {
        case openFileWrite = 0x02, deleteFile = 0x03, writeFileData = 0x04, getFileSize = 0x05
        case openFileRead = 0x06, readFileDataRequest = 0x07, readFileDataResponse = 0x09
        case findClose = 0x0a, closeFile = 0x0c, unknown0D = 0x0d, formatWatch = 0x0e
        case resetDevice = 0x10, findFirstFile = 0x11, findNextFile = 0x12, getCurrentTime = 0x14
        case unknown1A = 0x1a, resetGPSProcessor = 0x1d, unknown1F = 0x1f, getProductID = 0x20
        case getFirmwareVersion = 0x21, unknown22 = 0x22, unknown23 = 0x23, getBLEVersion = 0x28
    }

    public let transport: HIDTransport
    public var model: WatchModel { transport.model }
    private var counter: UInt8 = 0
    public var progress: ((Int, Int) -> Void)?

    public init(transport: HIDTransport) {
        self.transport = transport
    }

    public static func connect() throws -> Watch {
        let w = Watch(transport: try HIDTransport())
        try w.startup()
        return w
    }

    // MARK: - Framing

    @discardableResult
    func request(_ msg: Msg, _ payload: [UInt8] = [], expect: Msg? = nil, timeout: TimeInterval = 5) throws -> [UInt8] {
        precondition(payload.count < model.packetSize - 4)
        let sent = counter
        counter &+= 1
        try transport.send([0x09, UInt8(payload.count + 2), sent, msg.rawValue] + payload)
        let r = try transport.receive(timeout: timeout)
        let expected = (expect ?? msg).rawValue
        guard r.count >= 4, r[0] == 0x01 else { throw WatchError.badResponse("header \(r.prefix(4).map { String(format: "%02x", $0) })") }
        guard r[2] == sent else { throw WatchError.badResponse("counter \(r[2]) != \(sent)") }
        guard r[3] == expected else { throw WatchError.badResponse(String(format: "type 0x%02x, expected 0x%02x", r[3], expected)) }
        let len = Int(r[1]) - 2
        guard len >= 0, 4 + len <= r.count else { throw WatchError.badResponse("length \(r[1])") }
        return Array(r[4..<(4 + len)])
    }

    /// File operation response: [0..3] ?, [4..7] file id, [16..19] error code.
    private func fileOp(_ msg: Msg, _ id: UInt32, name: String) throws {
        var p = [UInt8](); p.appendBE(id)
        let r = try request(msg, p)
        let code = r.count >= 20 ? r.u32be(16) : 0
        if code != 0 { throw WatchError.fileError(op: name, fileID: id, code: code) }
    }

    // MARK: - Session

    /// The message sequence the official software sends after connecting.
    public func startup() throws {
        for m: Msg in [.unknown0D, .findClose, .unknown22, .unknown22, .getProductID, .findClose, .getBLEVersion, .getBLEVersion, .unknown1F] {
            try request(m)
        }
    }

    public func productID() throws -> UInt32 { try request(.getProductID).u32be(0) }

    public func firmwareVersion() throws -> String {
        String(decoding: try request(.getFirmwareVersion).prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func bleVersion() throws -> UInt32 { try request(.getBLEVersion).u32be(0) }

    /// The watch clock, in UTC (synchronised from GPS).
    public func currentTime() throws -> Date {
        Date(timeIntervalSince1970: TimeInterval(try request(.getCurrentTime).u32be(0)))
    }

    // MARK: - Files

    public func listFiles(type: UInt32? = nil) throws -> [WatchFile] {
        var files: [WatchFile] = []
        var r = try request(.findFirstFile, [UInt8](repeating: 0, count: 8))
        while r.count >= 20, r.u32be(16) == 0 {
            let f = WatchFile(id: r.u32be(4), size: Int(r.u32be(12)))
            if type == nil || f.id & FileID.typeMask == type { files.append(f) }
            r = try request(.findNextFile)
        }
        return files.sorted { $0.id < $1.id }
    }

    public func exists(_ id: UInt32) -> Bool {
        do {
            try fileOp(.openFileRead, id, name: "open")
            try? fileOp(.closeFile, id, name: "close")
            return true
        } catch { return false }
    }

    public func readFile(_ id: UInt32) throws -> [UInt8] {
        try fileOp(.openFileRead, id, name: "open")
        defer { try? fileOp(.closeFile, id, name: "close") }

        var p = [UInt8](); p.appendBE(id)
        let sizeResp = try request(.getFileSize, p)
        let size = Int(sizeResp.u32be(12))
        var data = [UInt8](); data.reserveCapacity(size)
        while data.count < size {
            let n = min(model.readChunk, size - data.count)
            var q = [UInt8](); q.appendBE(id); q.appendBE(UInt32(n))
            let r = try request(.readFileDataRequest, q, expect: .readFileDataResponse)
            guard r.count >= 8, r.u32be(0) == id, Int(r.u32be(4)) == n, r.count >= 8 + n else {
                throw WatchError.badResponse("short read of \(id.hex)")
            }
            data += r[8..<(8 + n)]
            progress?(data.count, size)
        }
        return data
    }

    public func writeFile(_ id: UInt32, _ data: [UInt8]) throws {
        try fileOp(.openFileWrite, id, name: "open for write")
        var offset = 0
        while offset < data.count {
            let n = min(model.writeChunk, data.count - offset)
            var p = [UInt8](); p.appendBE(id); p += data[offset..<(offset + n)]
            let r = try request(.writeFileData, p)
            guard r.count >= 8, r.u32be(4) == id else { throw WatchError.badResponse("write ack for \(id.hex)") }
            offset += n
            progress?(offset, data.count)
        }
        try fileOp(.closeFile, id, name: "close")
    }

    public func writeVerified(_ id: UInt32, _ data: [UInt8]) throws {
        try writeFile(id, data)
        guard try readFile(id) == data else { throw WatchError.verifyFailed(id) }
    }

    public func deleteFile(_ id: UInt32) throws {
        try fileOp(.deleteFile, id, name: "delete")
    }

    /// Reloads the GPS chip after new QuickFix data has been written.
    public func resetGPSProcessor() throws {
        try request(.resetGPSProcessor, timeout: 20)
    }
}
