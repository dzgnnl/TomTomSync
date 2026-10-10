import Foundation

/// Names for the product ID in the ttbin header (also reported by USB message 0x20).
public enum TomTomProduct {
    /// Confirmed mappings only. Unknown IDs fall back to a generic name.
    static let names: [UInt16: String] = [:]

    public static func name(_ productID: UInt16) -> String {
        names[productID] ?? "TomTom GPS Watch"
    }
}

extension Activity {
    public var distance: Double { summaryDistance ?? points.last?.distance ?? 0 }

    /// Sports where the watch's per-second "cycles" value counts steps.
    var countsSteps: Bool { [.running, .trailRunning, .hiking].contains(sport) }

    private func inPeriod(_ t: Date) -> Bool { periods.contains { t >= $0.start && t <= $0.end } }

    /// Average cadence in steps per minute over moving time.
    public var averageCadence: Double? {
        guard countsSteps else { return nil }
        let moving = points.filter { inPeriod($0.time) }
        let steps = moving.compactMap(\.steps).reduce(0) { $0 + Int($1) }
        guard steps > 0, timerTime > 0 else { return nil }
        return Double(steps) / timerTime * 60
    }

    /// Per-point cadence in steps per minute, smoothed over a 20-second window
    /// (the watch reports whole steps per second, i.e. 2 or 3).
    public var cadenceSeries: [Double?] {
        guard countsSteps else { return points.map { _ in nil } }
        var out: [Double?] = []
        var window: [(Date, Int)] = []
        var sum = 0
        for p in points {
            guard let s = p.steps else { out.append(nil); continue }
            window.append((p.time, Int(s))); sum += Int(s)
            while let first = window.first, p.time.timeIntervalSince(first.0) >= 20 { sum -= first.1; window.removeFirst() }
            let span = max(1, p.time.timeIntervalSince(window.first!.0) + 1)
            out.append(Double(sum) / span * 60)
        }
        return out
    }

    /// Text for the Strava activity description: data Strava does not show itself.
    public var stravaDescription: String? {
        var lines: [String] = []
        if let r = hrRecovery { lines.append("Heart rate recovery: −\(r.drop) bpm in 1 min") }
        if let c = averageCadence { lines.append("Avg cadence \(Int(c.rounded())) spm") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
