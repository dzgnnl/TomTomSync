import Foundation

/// Converts a parsed ttbin `Activity` into a FIT activity file.
public enum ActivityFIT {
    // Global message numbers
    private static let fileID: UInt16 = 0, session: UInt16 = 18, lap: UInt16 = 19
    private static let record: UInt16 = 20, event: UInt16 = 21, deviceInfo: UInt16 = 23, activity: UInt16 = 34

    private static let manufacturerTomTom: Int64 = 71

    /// FIT (sport, sub_sport) for a TomTom activity type.
    static func fitSport(_ s: TTSport?) -> (Int64, Int64) {
        switch s {
        case .running: return (1, 0)
        case .trailRunning: return (1, 3)
        case .treadmill: return (1, 1)
        case .cycling: return (2, 0)
        case .indoorCycling: return (2, 6)
        case .swimming: return (5, 17)        // lap swimming
        case .gym: return (10, 20)            // training / strength
        case .hiking: return (17, 0)
        case .skiing: return (13, 0)          // alpine skiing
        case .snowboarding: return (14, 0)
        case .freestyle, .none: return (0, 0)
        }
    }

    /// `x * factor` rounded; nil (FIT "invalid") for NaN, infinity or values that
    /// do not fit, which a corrupt ttbin can produce.
    static func scaled(_ x: Double?, _ factor: Double) -> Int64? {
        guard let v = x.map({ ($0 * factor).rounded() }), v.isFinite, abs(v) < 1e15 else { return nil }
        return Int64(v)
    }
    private static func semicircles(_ deg: Double?) -> Int64? { scaled(deg, 2_147_483_648.0 / 180.0) }
    private static func ms(_ t: TimeInterval) -> Int64? { scaled(t, 1000) }
    private static func cm(_ m: Double?) -> Int64? { scaled(m, 100) }
    private static let ts = FITWriter.timestamp

    public static func encode(_ a: Activity, serialNumber: UInt32? = nil) -> [UInt8] {
        var w = FITWriter()
        let (sport, subSport) = fitSport(a.sport)
        let start = min(a.periods.first?.start ?? .distantFuture, a.points.first?.time ?? a.startTime)
        let end = max(a.endTime, a.points.last?.time ?? a.endTime)
        let totalDistance = a.summaryDistance ?? a.points.last?.distance ?? 0
        let totalCalories = a.summaryCalories.map { Int64($0) } ?? a.points.last?.calories.map { Int64($0) }
        let timer = a.timerTime > 0 ? a.timerTime : end.timeIntervalSince(start)

        // file_id
        w.define(.init(global: fileID, fields: [
            .init(number: 0, type: .enumType),   // type
            .init(number: 1, type: .uint16),     // manufacturer
            .init(number: 2, type: .uint16),     // product
            .init(number: 3, type: .uint32z),    // serial_number
            .init(number: 4, type: .uint32),     // time_created
            .string(8, bytes: 32),               // product_name
        ]))
        let productName = TomTomProduct.name(a.productID)
        w.write(fileID, [Int64(4), manufacturerTomTom, Int64(a.productID), serialNumber.map { Int64($0) } ?? 0,
                         ts(a.startTime), productName])

        // device_info for the recording device (device_index 0 = creator)
        w.define(.init(global: deviceInfo, fields: [
            .init(number: 253, type: .uint32), .init(number: 0, type: .uint8), .init(number: 2, type: .uint16),
            .init(number: 4, type: .uint16), .init(number: 3, type: .uint32z), .string(27, bytes: 32),
        ]))
        w.write(deviceInfo, [ts(a.startTime), Int64(0), manufacturerTomTom, Int64(a.productID),
                             serialNumber.map { Int64($0) } ?? 0, productName])

        // event: timer start/stop
        w.define(.init(global: event, fields: [
            .init(number: 253, type: .uint32), .init(number: 0, type: .enumType), .init(number: 1, type: .enumType),
        ]))
        func timerEvent(_ t: Date, start: Bool) { w.write(event, [ts(t), Int64(0), Int64(start ? 0 : 4)]) }

        // record
        w.define(.init(global: record, fields: [
            .init(number: 253, type: .uint32),   // timestamp
            .init(number: 0, type: .sint32),     // position_lat
            .init(number: 1, type: .sint32),     // position_long
            .init(number: 5, type: .uint32),     // distance (cm)
            .init(number: 73, type: .uint32),    // enhanced_speed (mm/s)
            .init(number: 3, type: .uint8),      // heart_rate
            .init(number: 33, type: .uint16),    // calories
            .init(number: 4, type: .uint8),      // cadence (running: strides/min)
            .init(number: 53, type: .uint8),     // fractional_cadence (1/128)
        ]))
        // FIT running cadence is in strides (= steps / 2) per minute.
        let cadence = a.cadenceSeries
        func strides(_ spm: Double?) -> (Int64?, Int64?) {
            guard let spm, spm > 0 else { return (nil, nil) }
            guard let units = scaled(spm, 64) else { return (nil, nil) }   // strides/min in 1/128 units
            return (units / 128, units % 128)
        }

        var periods = a.periods[...]
        var running = false
        for (i, p) in a.points.enumerated() {
            if !running, let period = periods.first, p.time >= period.start {
                timerEvent(period.start, start: true); running = true
            }
            if running, let period = periods.first, p.time > period.end {
                timerEvent(period.end, start: false); running = false
                periods = periods.dropFirst()
                if let next = periods.first, p.time >= next.start { timerEvent(next.start, start: true); running = true }
            }
            w.write(record, [ts(p.time), semicircles(p.latitude), semicircles(p.longitude), cm(p.distance),
                             scaled(p.speed, 1000), p.heartRate.map { Int64($0) },
                             p.calories.map { Int64($0) }, strides(cadence[i]).0, strides(cadence[i]).1])
        }
        if !running, let period = periods.first { timerEvent(period.start, start: true); running = true }
        if running { timerEvent(periods.first?.end ?? end, start: false) }

        // Heart rate recovery: FIT's recovery_hr event carries the heart rate
        // reached after the recovery period, so derive it from the last sample.
        if let rec = a.hrRecovery, let lastHR = a.points.last(where: { $0.heartRate != nil })?.heartRate {
            w.define(.init(global: event, fields: [
                .init(number: 253, type: .uint32), .init(number: 0, type: .enumType),
                .init(number: 1, type: .enumType), .init(number: 3, type: .uint32),
            ]))
            let t = (a.periods.last?.end ?? end).addingTimeInterval(60)
            w.write(event, [ts(t), Int64(21), Int64(3), Int64(max(0, Int(lastHR) - rec.drop))])
        }

        // laps
        w.define(.init(global: lap, fields: [
            .init(number: 253, type: .uint32),   // timestamp
            .init(number: 2, type: .uint32),     // start_time
            .init(number: 7, type: .uint32),     // total_elapsed_time (ms)
            .init(number: 8, type: .uint32),     // total_timer_time (ms)
            .init(number: 9, type: .uint32),     // total_distance (cm)
            .init(number: 11, type: .uint16),    // total_calories
            .init(number: 15, type: .uint8),     // avg_heart_rate
            .init(number: 16, type: .uint8),     // max_heart_rate
            .init(number: 0, type: .enumType),   // event
            .init(number: 1, type: .enumType),   // event_type
            .init(number: 25, type: .enumType),  // sport
            .init(number: 39, type: .enumType),  // sub_sport
        ]))
        // Watch laps carry cumulative values; the final lap runs to the end.
        var lapEnds = a.laps.map { ($0.endTime, $0.elapsed, $0.distance, Int64($0.calories)) }
        if lapEnds.last.map({ end.timeIntervalSince($0.0) > 1 }) ?? true {
            lapEnds.append((end, timer, totalDistance, totalCalories ?? 0))
        }
        var prev = (start, 0.0 as TimeInterval, 0.0, 0 as Int64)
        var pointIndex = 0
        for l in lapEnds {
            while pointIndex < a.points.count && a.points[pointIndex].time <= prev.0 { pointIndex += 1 }
            var lapHRSum = 0
            var lapHRCount = 0
            var lapMaxHR: UInt8?
            while pointIndex < a.points.count && a.points[pointIndex].time <= l.0 {
                if let hr = a.points[pointIndex].heartRate {
                    lapHRSum += Int(hr)
                    lapHRCount += 1
                    lapMaxHR = max(lapMaxHR ?? hr, hr)
                }
                pointIndex += 1
            }
            w.write(lap, [ts(l.0), ts(prev.0), ms(l.0.timeIntervalSince(prev.0)), ms(max(0, l.1 - prev.1)),
                          cm(max(0, l.2 - prev.2)), max(0, l.3 - prev.3),
                          lapHRCount == 0 ? nil : Int64(lapHRSum / lapHRCount), lapMaxHR.map { Int64($0) },
                          9, 1, sport, subSport])
            prev = l
        }

        // session
        let hr = a.points.compactMap(\.heartRate)
        w.define(.init(global: session, fields: [
            .init(number: 253, type: .uint32), .init(number: 2, type: .uint32),
            .init(number: 7, type: .uint32), .init(number: 8, type: .uint32),
            .init(number: 9, type: .uint32), .init(number: 11, type: .uint16),
            .init(number: 16, type: .uint8), .init(number: 17, type: .uint8),
            .init(number: 124, type: .uint32),   // enhanced_avg_speed (mm/s)
            .init(number: 5, type: .enumType), .init(number: 6, type: .enumType),
            .init(number: 25, type: .uint16),    // first_lap_index
            .init(number: 26, type: .uint16),    // num_laps
            .init(number: 0, type: .enumType), .init(number: 1, type: .enumType),
            .init(number: 18, type: .uint8),     // avg_cadence
            .init(number: 92, type: .uint8),     // avg_fractional_cadence
        ]))
        let avgCadence = strides(a.averageCadence)
        w.write(session, [ts(end), ts(start), ms(end.timeIntervalSince(start)), ms(timer), cm(totalDistance), totalCalories,
                          hr.isEmpty ? nil : Int64(hr.map(Int.init).reduce(0, +) / hr.count), hr.max().map { Int64($0) },
                          timer > 0 ? scaled(totalDistance / timer, 1000) : nil,
                          sport, subSport, 0, Int64(lapEnds.count), 8, 1, avgCadence.0, avgCadence.1])

        // activity
        w.define(.init(global: activity, fields: [
            .init(number: 253, type: .uint32), .init(number: 0, type: .uint32), .init(number: 1, type: .uint16),
            .init(number: 2, type: .enumType), .init(number: 3, type: .enumType), .init(number: 4, type: .enumType),
            .init(number: 5, type: .uint32),     // local_timestamp
        ]))
        w.write(activity, [ts(end), ms(timer), 1, 0, 26, 1, ts(end) + Int64(a.localOffset)])

        return w.finish()
    }
}
