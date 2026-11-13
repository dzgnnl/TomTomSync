import Foundation

/// A route to follow on the watch: a name and one or more segments of points.
public struct Route: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var latitude: Double
        public var longitude: Double
        public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    }

    public var name: String
    public var segments: [[Point]]

    public init(name: String, segments: [[Point]]) {
        self.name = name
        self.segments = segments
    }

    public var pointCount: Int { segments.reduce(0) { $0 + $1.count } }

    /// Length along the segments, in metres.
    public var length: Double {
        segments.reduce(0) { total, seg in
            total + zip(seg, seg.dropFirst()).reduce(0) { $0 + Route.distance($1.0, $1.1) }
        }
    }

    /// Haversine distance in metres.
    static func distance(_ a: Point, _ b: Point) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * rad, dLon = (b.longitude - a.longitude) * rad
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * rad) * cos(b.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}

// MARK: - GPX

public enum GPXError: Error, CustomStringConvertible {
    case invalid(String)
    case noPoints
    case tooLarge(Int)

    public var description: String {
        switch self {
        case .invalid(let s): return "Not a valid GPX file: \(s)"
        case .noPoints: return "The GPX file contains no track or route points"
        case .tooLarge(let n): return "The GPX file is too large (\(n / 1_048_576) MB)"
        }
    }
}

public enum GPX {
    /// Larger files are almost certainly not a single route.
    static let maximumFileSize = 50 * 1024 * 1024

    public static func read(_ url: URL) throws -> Route {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumFileSize else { throw GPXError.tooLarge(size) }
        let fallback = url.deletingPathExtension().lastPathComponent
        return try parse(Data(contentsOf: url), fallbackName: fallback)
    }

    /// Reads tracks (`trk`/`trkseg`/`trkpt`) and routes (`rte`/`rtept`). Each
    /// track segment and each route becomes one segment. Waypoints, elevation
    /// and times are ignored. The name comes from the first track or route,
    /// then the metadata, then `fallbackName`.
    public static func parse(_ data: Data, fallbackName: String) throws -> Route {
        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw GPXError.invalid(delegate.invalidPoint
                ?? parser.parserError?.localizedDescription ?? "parse error")
        }
        let segments = delegate.segments.filter { !$0.isEmpty }
        guard !segments.isEmpty else { throw GPXError.noPoints }
        let name = [delegate.trackName, delegate.metadataName].compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? fallbackName
        return Route(name: name, segments: segments)
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var segments: [[Route.Point]] = []
        var trackName: String?
        var metadataName: String?
        /// Set when a point is broken: the whole file is rejected rather than
        /// quietly shortened, so a damaged copy never replaces a good one.
        var invalidPoint: String?
        private var pointCount = 0
        private var path: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let name = localName(element)
            path.append(name)
            text = ""
            switch name {
            case "trkseg", "rte": segments.append([])
            case "trkpt", "rtept":
                pointCount += 1
                guard let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init),
                      (-90...90).contains(lat), (-180...180).contains(lon), !segments.isEmpty else {
                    invalidPoint = "point \(pointCount) has no valid coordinate"
                    parser.abortParsing()
                    return
                }
                segments[segments.count - 1].append(Route.Point(latitude: lat, longitude: lon))
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if localName(element) == "name", path.count >= 2 {
                switch path[path.count - 2] {
                case "trk", "rte": if trackName == nil { trackName = text }
                case "metadata": if metadataName == nil { metadataName = text }
                default: break
                }
            }
            path.removeLast()
        }

        private func localName(_ element: String) -> String {
            element.split(separator: ":").last.map(String.init) ?? element
        }
    }

    /// A GPX 1.1 track with one `trkseg` per segment.
    public static func write(_ route: Route) -> Data {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="TomTomSync" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(esc(route.name))</name>

        """
        for seg in route.segments {
            s += "    <trkseg>\n"
            for p in seg { s += String(format: "      <trkpt lat=\"%.7f\" lon=\"%.7f\"/>\n", p.latitude, p.longitude) }
            s += "    </trkseg>\n"
        }
        s += "  </trk>\n</gpx>\n"
        return Data(s.utf8)
    }
}

// MARK: - Simplification

extension Route {
    public struct Simplified: Sendable {
        public var route: Route
        public var originalPointCount: Int
        /// Largest distance between a removed point and the simplified line, in metres.
        public var maximumDeviation: Double

        /// "5.6 km, 2123 → 500 points, max 0.4 m off"
        public var summary: String {
            let km = String(format: "%.1f km", route.length / 1000)
            guard originalPointCount > route.pointCount else { return "\(km), \(route.pointCount) points" }
            let off = maximumDeviation < 10 ? String(format: "%.1f", maximumDeviation) : String(format: "%.0f", maximumDeviation)
            return "\(km), \(originalPointCount) → \(route.pointCount) points, max \(off) m off"
        }
    }

    /// Reduces the route to at most `maximumPoints` points with the
    /// Douglas-Peucker algorithm, ranked so that it stops at a point count
    /// instead of a distance tolerance:
    ///
    /// 1. Each point gets an importance: its distance to the line between the
    ///    points that surround it at the step where Douglas-Peucker would keep
    ///    it. Every segment's first and last point is always kept.
    /// 2. The `maximumPoints` most important points over all segments are kept.
    ///
    /// Distances are measured in metres on a local flat projection. Unlike
    /// keeping every n-th point, this keeps corners and the tips of
    /// out-and-back sections.
    public func simplified(maximumPoints: Int) -> Simplified {
        let original = pointCount
        guard original > maximumPoints else { return Simplified(route: self, originalPointCount: original, maximumDeviation: 0) }

        let all = segments.flatMap { $0 }
        let lat0 = all.map(\.latitude).reduce(0, +) / Double(all.count) * Double.pi / 180
        let mPerDeg = 6_371_000.0 * Double.pi / 180
        // Longitudes relative to the first point, wrapped to ±180°, so a route
        // crossing the 180° meridian stays continuous (179.99° and −179.99°
        // are a few km apart, not 40,000).
        let lon0 = all[0].longitude
        func xy(_ p: Point) -> SIMD2<Double> {
            SIMD2(remainder(p.longitude - lon0, 360) * mPerDeg * cos(lat0), p.latitude * mPerDeg)
        }

        // (segment, index, importance)
        let projected = segments.map { $0.map(xy) }
        var ranked: [(Int, Int, Double)] = []
        for (s, pts) in projected.enumerated() {
            for (i, imp) in Self.importance(pts).enumerated() { ranked.append((s, i, imp)) }
        }
        ranked.sort { $0.2 > $1.2 }

        var keep = segments.map { [Bool](repeating: false, count: $0.count) }
        for (s, i, _) in ranked.prefix(maximumPoints) { keep[s][i] = true }

        // Actual deviation: each removed point against the line between the
        // kept points on either side of it.
        var deviation = 0.0
        for (s, pts) in projected.enumerated() {
            var last = 0
            for i in pts.indices.dropFirst() where keep[s][i] {
                for j in (last + 1)..<i { deviation = max(deviation, Self.distanceToSegment(pts[j], pts[last], pts[i])) }
                last = i
            }
        }
        let newSegments = segments.enumerated().map { s, seg in seg.enumerated().filter { keep[s][$0.offset] }.map(\.element) }
            .filter { !$0.isEmpty }
        return Simplified(route: Route(name: name, segments: newSegments), originalPointCount: original,
                          maximumDeviation: deviation)
    }

    /// Douglas-Peucker importance per point; endpoints are infinite. A point's
    /// importance is capped at its parent's, so keeping the top N gives the
    /// same result as Douglas-Peucker with some tolerance. Iterative, so long
    /// tracks can't overflow the stack.
    static func importance(_ p: [SIMD2<Double>]) -> [Double] {
        var imp = [Double](repeating: 0, count: p.count)
        guard !p.isEmpty else { return imp }
        imp[0] = .infinity; imp[p.count - 1] = .infinity
        var stack: [(Int, Int, Double)] = [(0, p.count - 1, .infinity)]
        while let (a, b, cap) = stack.popLast() {
            guard b - a > 1 else { continue }
            var best = a + 1, bestD = -1.0
            for i in (a + 1)..<b {
                let d = distanceToSegment(p[i], p[a], p[b])
                if d > bestD { bestD = d; best = i }
            }
            // Every point lies on the chord (e.g. standing still): all keep
            // importance 0. Splitting further would rescan the span point by
            // point, which is quadratic.
            guard bestD > 0 else { continue }
            let v = min(bestD, cap)
            imp[best] = v
            stack.append((a, best, v)); stack.append((best, b, v))
        }
        return imp
    }

    /// Distance from `p` to the line segment a–b (not the infinite line, so a
    /// turnaround beyond the chord still counts as far away).
    static func distanceToSegment(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a, ap = p - a
        let len2 = (ab * ab).sum()
        let t = len2 == 0 ? 0 : max(0, min(1, (ap * ab).sum() / len2))
        let d = ap - ab * t
        return (d * d).sum().squareRoot()
    }
}
