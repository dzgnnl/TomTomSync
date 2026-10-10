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

    /// Speed sports are shown as km/h, swimming per 100 m, the rest as pace per km.
    public var averagePaceText: String? {
        let t = timerTime
        guard distance >= 10, t > 0 else { return nil }
        func mmss(_ s: Double) -> String { let s = Int(s.rounded()); return String(format: "%d:%02d", s / 60, s % 60) }
        switch sport {
        case .cycling, .indoorCycling, .skiing, .snowboarding:
            return String(format: "Avg speed %.1f km/h", distance / t * 3.6)
        case .swimming:
            return "Avg pace \(mmss(t / distance * 100)) /100m"
        default:
            return "Avg pace \(mmss(t / distance * 1000)) /km"
        }
    }

    /// Text for the Strava activity description: data Strava does not show itself.
    public var stravaDescription: String {
        var lines: [String] = []
        if let p = averagePaceText { lines.append(p) }
        if let r = hrRecovery { lines.append("Heart rate recovery: −\(r.drop) bpm in 1 min (TomTom score \(r.score))") }
        if let f = fitnessPoints, f > 0 { lines.append("TomTom fitness points: \(f)") }
        lines.append("Recorded with \(TomTomProduct.name(productID))")
        return lines.joined(separator: "\n")
    }
}
