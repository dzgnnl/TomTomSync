import Foundation

/// The watch's route file ("trail"), one per route at file IDs
/// `0x00B80000`–`0x00B8000E`. Protobuf; the layout is described in
/// docs/DEVELOPMENT.md.
public enum RouteFile {
    public static let fileType: UInt32 = 0x00b8_0000
    public static let maximumRoutes = 15
    /// MySports reduced routes to 500 points. Whether the watch enforces it is untested.
    public static let maximumPoints = 500
    /// Longer names are cut off. To be checked on a watch's Trails list.
    public static let maximumNameLength = 32

    static let manufacturer: UInt32 = 0x1234_daeb
    static let routeFileType: UInt32 = 0x0007_0100
    /// Origin and rate of the timestamp field, found by TomTomWatch.
    static let timeOrigin = Date(timeIntervalSince1970: 1_457_332_197)   // 2016-03-07 06:29:57 UTC
    static let ticksPerSecond = 3.45559

    public static func fileID(slot: Int) -> UInt32 { fileType | UInt32(slot) }

    public enum DecodeError: Error { case notARouteFile, noPoints }

    /// Encodes a route that is already within `maximumPoints`.
    public static func encode(_ route: Route, name: String, date: Date = Date()) -> [UInt8] {
        let segments = route.segments.filter { !$0.isEmpty }
        let all = segments.flatMap { $0 }
        func e7(_ v: Double) -> UInt32 { UInt32(bitPattern: Int32((v * 1e7).rounded())) }
        func latLon(_ w: inout ProtoWriter, _ field: Int, _ v: Double) { w.message(field) { $0.fixed32(1, e7(v)) } }
        func coordinate(_ w: inout ProtoWriter, _ field: Int, _ p: Route.Point) {
            w.message(field) { latLon(&$0, 1, p.latitude); latLon(&$0, 2, p.longitude) }
        }

        var time = [UInt8](repeating: 0, count: 16)
        let ticks = UInt64(max(0, date.timeIntervalSince(timeOrigin) * ticksPerSecond))
        for i in 0..<8 { time[8 + i] = UInt8(ticks >> (8 * (7 - i)) & 0xff) }   // big-endian at offset 8

        var root = ProtoWriter()
        root.message(1) { c in c.message(7) { $0.fixed32(1, manufacturer); $0.fixed32(2, routeFileType) } }
        root.message(1) { c in c.message(8) { d in d.message(1) { t in
            t.message(1) { m in
                m.string(1, name)
                m.message(2) { box in
                    latLon(&box, 1, all.map(\.latitude).min() ?? 0)
                    latLon(&box, 2, all.map(\.longitude).min() ?? 0)
                    latLon(&box, 3, all.map(\.latitude).max() ?? 0)
                    latLon(&box, 4, all.map(\.longitude).max() ?? 0)
                }
                m.data(3, time)
            }
            // Start and end of the first segment, with index 1 and 2.
            if let first = segments.first?.first, let last = segments.first?.last {
                for (i, p) in [first, last].enumerated() {
                    t.message(2) { coordinate(&$0, 1, p); $0.int32(2, Int32(i + 1)) }
                }
            }
            t.message(3) { s in
                s.int32(1, Int32(segments.count))
                for seg in segments {
                    s.message(2) { g in
                        g.int32(1, Int32(seg.count))
                        for p in seg { g.message(2) { coordinate(&$0, 1, p) } }
                    }
                }
            }
        } } }
        return root.bytes
    }

    public static func decode(_ bytes: [UInt8]) throws -> Route {
        let root = try ProtoReader.fields(bytes)
        var isRoute = false
        var track: [ProtoField]?
        for container in root.all(1) {
            let c = try container.message()
            if let meta = try c.first(7)?.message() {
                isRoute = meta.first(1)?.uint32 == manufacturer && meta.first(2)?.uint32 == routeFileType
            }
            if let data = try c.first(8)?.message(), let t = try data.first(1)?.message() { track = t }
        }
        guard isRoute, let track else { throw DecodeError.notARouteFile }

        func latLon(_ f: ProtoField?) throws -> Double? {
            guard let v = try f?.message().first(1)?.uint32 else { return nil }
            return Double(Int32(bitPattern: v)) / 1e7
        }
        let name = try track.first(1)?.message().first(1)?.string ?? ""
        var segments: [[Route.Point]] = []
        for seg in try track.first(3)?.message().all(2) ?? [] {
            segments.append(try seg.message().all(2).compactMap { cd in
                guard let c = try cd.message().first(1)?.message(),
                      let lat = try latLon(c.first(1)), let lon = try latLon(c.first(2)) else { return nil }
                return Route.Point(latitude: lat, longitude: lon)
            })
        }
        segments.removeAll { $0.isEmpty }
        guard !segments.isEmpty else { throw DecodeError.noPoints }
        return Route(name: name, segments: segments)
    }

    /// A name the watch can show: diacritics removed, printable ASCII only,
    /// single spaces, at most `maximumNameLength` characters.
    public static func watchName(_ name: String) -> String {
        let folded = name.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? name
        let ascii = String(folded.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7f }.map(Character.init))
        let words = ascii.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let short = String(words.prefix(maximumNameLength)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? "Route" : short
    }
}
