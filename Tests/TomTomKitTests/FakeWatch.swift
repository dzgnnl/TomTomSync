import Foundation
@testable import TomTomKit

/// An in-memory watch that answers the USB protocol the way `Watch` expects:
/// a file store plus switches to make it misbehave.
final class FakeWatch: WatchTransport {
    let model: WatchModel = .sparkMusic
    var serialNumber: String? = "AB1234C56789"
    var files: [UInt32: [UInt8]] = [:]
    /// Not on the list of watches without route support.
    var productID: UInt32 = 0x0000_0BB8

    /// Files that can't be opened for reading.
    var unreadable: Set<UInt32> = []
    /// Files the watch refuses to delete.
    var undeletable: Set<UInt32> = []
    /// Stores something else than what was written.
    var corruptsWrites = false
    /// Message types answered with an empty payload.
    var shortReplies: Set<UInt8> = []
    /// The cable is pulled after this many more requests.
    var requestsUntilDisconnect: Int?

    private(set) var deleted: [UInt32] = []
    private(set) var written: [UInt32] = []
    private(set) var isClosed = false

    private var reply: [UInt8]?
    private var listing: [UInt32] = []
    private var readOffset: [UInt32: Int] = [:]

    func close() { isClosed = true }

    func receive(timeout: TimeInterval) throws -> [UInt8] {
        guard let r = reply else { throw TransportError.timeout }
        reply = nil
        return r
    }

    func send(_ p: [UInt8]) throws {
        if let n = requestsUntilDisconnect {
            guard n > 0 else { throw TransportError.disconnected }
            requestsUntilDisconnect = n - 1
        }
        let counter = p[2], type = p[3]
        let payload = Array(p[4..<(2 + Int(p[1]))])
        func respond(_ payload: [UInt8], type t: UInt8? = nil) {
            reply = [0x01, UInt8(payload.count + 2), counter, t ?? type] + (shortReplies.contains(type) ? [] : payload)
            if shortReplies.contains(type) { reply![1] = 2 }
        }
        /// [4..7] file id, [12..15] size, [16..19] error code.
        func fileReply(_ id: UInt32, size: Int = 0, error: UInt32 = 0) -> [UInt8] {
            var r = [UInt8](repeating: 0, count: 4); r.appendBE(id)
            r += [0, 0, 0, 0]; r.appendBE(UInt32(size)); r.appendBE(error)
            return r
        }
        func nextListed() -> [UInt8] {
            guard let id = listing.first else { return fileReply(0, error: 1) }
            listing.removeFirst()
            return fileReply(id, size: files[id]?.count ?? 0)
        }
        let id = payload.count >= 4 ? payload.u32be(0) : 0

        switch type {
        case 0x06:   // open for reading
            readOffset[id] = 0
            respond(fileReply(id, error: files[id] == nil || unreadable.contains(id) ? 1 : 0))
        case 0x02:   // open for writing: replaces the file
            files[id] = []; written.append(id)
            respond(fileReply(id))
        case 0x0c:   // close
            respond(fileReply(id))
        case 0x03:   // delete
            if undeletable.contains(id) || files[id] == nil { respond(fileReply(id, error: 1)); break }
            files[id] = nil; deleted.append(id)
            respond(fileReply(id))
        case 0x05:   // size
            respond(fileReply(id, size: files[id]?.count ?? 0))
        case 0x07:   // read: id, length
            let n = Int(payload.u32be(4)), from = readOffset[id] ?? 0
            let data = Array((files[id] ?? [])[from..<(from + n)])
            readOffset[id] = from + n
            var r = [UInt8](); r.appendBE(id); r.appendBE(UInt32(n))
            respond(r + data, type: 0x09)
        case 0x04:   // write: id, data
            let data = Array(payload.dropFirst(4))
            files[id, default: []] += corruptsWrites ? data.map { ~$0 } : data
            respond([0, 0, 0, 0] + payload.prefix(4))
        case 0x11:   // first file
            listing = files.keys.sorted().reversed()   // the watch lists in no particular order
            respond(nextListed())
        case 0x12:   // next file
            respond(nextListed())
        case 0x20:   // product ID, little-endian
            var r = [UInt8](); r.appendLE(productID); respond(r)
        case 0x14:   // current time
            var r = [UInt8](); r.appendBE(UInt32(Date().timeIntervalSince1970)); respond(r)
        case 0x21:
            respond(Array("1.7.64".utf8) + [0])
        case 0x28:
            respond([0, 0, 0, 1])
        default:
            respond([])
        }
    }
}
