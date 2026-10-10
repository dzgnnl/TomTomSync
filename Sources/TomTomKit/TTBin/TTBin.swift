import Foundation

/// TomTom activity types as stored in the ttbin status/summary records.
public enum TTSport: UInt8, Sendable {
    case running = 0, cycling = 1, swimming = 2, treadmill = 7, freestyle = 8, gym = 9
    case hiking = 10, indoorCycling = 11, trailRunning = 14, skiing = 15, snowboarding = 16

    public var name: String {
        switch self {
        case .running: return "running"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .treadmill: return "treadmill"
        case .freestyle: return "freestyle"
        case .gym: return "gym"
        case .hiking: return "hiking"
        case .indoorCycling: return "indoor-cycling"
        case .trailRunning: return "trail-running"
        case .skiing: return "skiing"
        case .snowboarding: return "snowboarding"
        }
    }
}

/// One sample, at most one per second.
public struct TrackPoint: Sendable {
    public var time: Date
    public var latitude: Double?          // degrees
    public var longitude: Double?
    public var distance: Double?          // cumulative metres
    public var speed: Double?             // m/s
    public var heartRate: UInt8?
    public var calories: UInt16?          // cumulative
    public var steps: UInt8?              // steps (running) taken in this second
}

public struct Lap: Sendable {
    public var endTime: Date
    public var elapsed: TimeInterval      // since activity start, as reported by the watch
    public var distance: Double           // cumulative metres
    public var calories: UInt16           // cumulative
}

/// A timer period: from start/resume to pause/stop.
public struct TimerPeriod: Sendable {
    public var start: Date
    public var end: Date
}

public struct Activity: Sendable {
    public var productID: UInt16
    public var firmware: String
    public var startTime: Date            // UTC
    public var localOffset: Int           // seconds east of UTC at recording time
    public var sport: TTSport?
    public var points: [TrackPoint] = []
    public var laps: [Lap] = []
    public var periods: [TimerPeriod] = []
    public var summaryDistance: Double?
    public var summaryDuration: TimeInterval?
    public var summaryCalories: UInt16?
    /// Heart rate drop during the first minute after pausing, with the watch's score.
    /// Only recorded when the activity stays paused for that minute.
    public var hrRecovery: (score: Int, drop: Int)?
    /// TomTom fitness points earned in this activity.
    public var fitnessPoints: Int?

    public var endTime: Date { periods.last?.end ?? points.last?.time ?? startTime }
    public var timerTime: TimeInterval { periods.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }
    public var hasGPS: Bool { points.contains { $0.latitude != nil } }
}

public enum TTBinError: Error, CustomStringConvertible {
    case notTTBin, truncated(Int), unknownTag(UInt8, Int), tooManyRecords(Int)

    public var description: String {
        switch self {
        case .notTTBin: return "Not a ttbin file"
        case .truncated(let o): return "ttbin file truncated at offset \(o)"
        case .unknownTag(let t, let o): return String(format: "Unknown ttbin record tag 0x%02x at offset %d", t, o)
        case .tooManyRecords(let maximum): return "ttbin file exceeds the \(maximum)-record processing limit"
        }
    }
}

/// Parser for the TomTom ttbin activity format.
///
/// The header contains a table of record lengths per tag (length includes the
/// tag byte; 0xFFFF means a u16 length follows the tag). Integers are
/// little-endian. GPS timestamps are UTC; all other timestamps are local time
/// (UTC + header.localOffset).
public enum TTBinParser {
    /// Prevent pathological files from amplifying a bounded byte stream into
    /// unbounded parser state, point arrays, and FIT output.
    static let maximumRecordCount = 250_000

    enum Tag: UInt8 {
        case header = 0x20, status = 0x21, gps = 0x22, heartRate = 0x25, summary = 0x27
        case lap = 0x2f, treadmill = 0x32, swim = 0x34, hrRecovery = 0x3f, gym = 0x41, fitnessPoints = 0x4a
    }

    enum Status: UInt8 { case ready = 0, active = 1, paused = 2, stopped = 3 }

    public static func parse(_ d: [UInt8]) throws -> Activity {
        guard d.count > 20, d[0] == Tag.header.rawValue else { throw TTBinError.notTTBin }
        let fileVersion = d.u16le(1)
        var p = 3
        let firmware: String
        if fileVersion <= 9 {
            firmware = "\(d[3]).\(d[4]).\(d[5])"; p += 3
        } else {
            firmware = "\(d.u16le(3)).\(d.u16le(5)).\(d.u16le(7))"; p += 6
        }
        guard d.count >= p + 6 + 16 + 80 + 10 else { throw TTBinError.truncated(p) }
        let productID = d.u16le(p)
        let localStart = Int(d.u32le(p + 2))
        p += 6 + 16 + 80
        // watchTime u32, localOffset i32, reserved u8, length count u8
        let localOffset = Int(d.i32le(p + 4))
        let lengthCount = Int(d[p + 9])
        p += 10
        var lengths: [UInt8: Int] = [:]
        for _ in 0..<lengthCount {
            guard p + 3 <= d.count else { throw TTBinError.truncated(p) }
            lengths[d[p]] = Int(d.u16le(p + 1))
            p += 3
        }

        /// Distances are floats; a corrupt record can hold NaN or absurd values.
        func metres(_ f: Float) -> Double? { f.isFinite && f >= 0 && f < 1e8 ? Double(f) : nil }

        func utc(local: UInt32) -> Date { Date(timeIntervalSince1970: TimeInterval(Int(local) - localOffset)) }

        var act = Activity(productID: productID, firmware: firmware,
                           startTime: Date(timeIntervalSince1970: TimeInterval(localStart - localOffset)),
                           localOffset: localOffset)
        var periodStart: Date?
        var lastDistance = 0.0

        var bySecond: [Int: TrackPoint] = [:]
        var lastTime = act.startTime

        /// Adds a sample, merging it with any other sample in the same second.
        func add(_ pt: TrackPoint) {
            let key = Int(pt.time.timeIntervalSince1970)
            lastTime = max(lastTime, pt.time)
            guard var m = bySecond[key] else { bySecond[key] = pt; return }
            m.latitude = pt.latitude ?? m.latitude; m.longitude = pt.longitude ?? m.longitude
            m.distance = pt.distance ?? m.distance; m.speed = pt.speed ?? m.speed
            m.heartRate = pt.heartRate ?? m.heartRate; m.calories = pt.calories ?? m.calories
            m.steps = pt.steps ?? m.steps
            bySecond[key] = m
        }

        var recordCount = 0
        while p < d.count {
            guard recordCount < maximumRecordCount else {
                throw TTBinError.tooManyRecords(maximumRecordCount)
            }
            recordCount += 1
            let tag = d[p]
            guard var len = lengths[tag] else { throw TTBinError.unknownTag(tag, p) }
            var body = p + 1
            if len == 0xFFFF {
                guard p + 3 <= d.count else { throw TTBinError.truncated(p) }
                len = Int(d.u16le(p + 1)) + 3   // tag + u16 length + data
                body = p + 3
            }
            guard len > 0, p + len <= d.count else {
                // A partial last record happens when the watch was reset mid-write; keep what we have.
                break
            }
            let r = Array(d[body..<(p + len)])

            switch Tag(rawValue: tag) {
            case .status where r.count >= 6:
                if act.sport == nil { act.sport = TTSport(rawValue: r[1]) }
                let t = utc(local: r.u32le(2))
                switch Status(rawValue: r[0]) {
                case .active:
                    if periodStart == nil { periodStart = t }
                case .paused, .stopped:
                    if let s = periodStart { act.periods.append(TimerPeriod(start: s, end: max(s, t))) }
                    periodStart = nil
                default: break
                }

            case .gps where r.count >= 27:
                let ts = r.u32le(12)
                guard ts != 0xFFFF_FFFF, ts != 0 else { break } // no fix yet
                let lat = Double(r.i32le(0)) / 1e7, lon = Double(r.i32le(4)) / 1e7
                if let dist = metres(r.f32le(22)) { lastDistance = max(lastDistance, dist) }
                add(TrackPoint(time: Date(timeIntervalSince1970: TimeInterval(ts)),
                               latitude: (lat == 0 && lon == 0) ? nil : lat,
                               longitude: (lat == 0 && lon == 0) ? nil : lon,
                               distance: lastDistance,
                               speed: Double(r.u16le(10)) / 100,
                               calories: r.u16le(16),
                               steps: r[26]))

            case .heartRate where r.count >= 6:
                let hr = r[0]
                guard hr > 0 else { break }
                add(TrackPoint(time: utc(local: r.u32le(2)), heartRate: hr))

            case .treadmill where r.count >= 16:
                if let dist = metres(r.f32le(4)) { lastDistance = max(lastDistance, dist) }
                add(TrackPoint(time: utc(local: r.u32le(0)), distance: lastDistance, calories: r.u16le(8)))

            case .swim where r.count >= 20:
                if let dist = metres(r.f32le(4)) { lastDistance = max(lastDistance, dist) }
                add(TrackPoint(time: utc(local: r.u32le(0)), distance: lastDistance, calories: r.u16le(18)))

            case .gym where r.count >= 10:
                add(TrackPoint(time: utc(local: r.u32le(0)), calories: r.u16le(4)))

            case .lap where r.count >= 10:
                let elapsed = TimeInterval(r.u32le(0))
                act.laps.append(Lap(endTime: lastTime,
                                    elapsed: elapsed, distance: metres(r.f32le(4)) ?? lastDistance, calories: r.u16le(8)))

            case .hrRecovery where r.count >= 8:
                let score = Int(r.i32le(0)), drop = Int(r.i32le(4))
                if drop > 0 { act.hrRecovery = (score, drop) }

            case .fitnessPoints where r.count >= 8:
                act.fitnessPoints = Int(r.u16le(6))

            case .summary where r.count >= 11:
                if let s = TTSport(rawValue: r[0]) { act.sport = s }
                act.summaryDistance = metres(r.f32le(1))
                act.summaryDuration = TimeInterval(r.u32le(5))
                act.summaryCalories = r.u16le(9)

            default: break
            }
            p += len
        }

        act.points = bySecond.values.sorted { $0.time < $1.time }
        if let s = periodStart, let last = act.points.last?.time {
            act.periods.append(TimerPeriod(start: s, end: max(s, last)))
        }
        if act.periods.isEmpty, let first = act.points.first, let last = act.points.last {
            act.periods.append(TimerPeriod(start: first.time, end: last.time))
        }
        return act
    }
}
