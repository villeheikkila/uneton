import Foundation
import Tagged

/// Derived presentation data. The SQLite projection remains the source of truth.
public struct SleepTrends: Sendable {
    public struct Day: Identifiable, Sendable {
        public var id: Date { date }
        public let date: Date
        public let hours: Double
        public let sessions: Int
    }

    public let days: [Day]
    public let completedSessions: [SleepSession]
    public let totalSeconds: TimeInterval
    public let averageSeconds: TimeInterval
    public let sessionCount: Int

    public init(sessions: [SleepSession], rangeDays: Int, now: Date, calendar: Calendar) {
        let range = max(0, rangeDays)
        days = (0..<range).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)),
                  let end = calendar.date(byAdding: .day, value: 1, to: day)
            else { return nil }
            let matching = sessions.filter { $0.startedAt < end && ($0.endedAt ?? now) > day }
            let seconds = matching.reduce(0.0) { total, session in
                total + max(0, min(end, session.endedAt ?? now).timeIntervalSince(max(day, session.startedAt)))
            }
            return Day(date: day, hours: seconds / 3_600, sessions: matching.count)
        }
        totalSeconds = days.reduce(0) { $0 + $1.hours * 3_600 }
        averageSeconds = days.isEmpty ? 0 : totalSeconds / Double(days.count)
        sessionCount = days.reduce(0) { $0 + $1.sessions }
        let cutoff = calendar.date(byAdding: .day, value: -range, to: now) ?? .distantPast
        completedSessions = sessions.filter { $0.startedAt >= cutoff && $0.endedAt != nil }
    }

    public static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}

public struct GrowthChartData: Sendable {
    public struct Measurement: Identifiable, Sendable {
        public let id: GrowthMeasurement.ID
        public let ageMonths: Double
        public let value: Double
    }

    public let curves: [GrowthReferencePoint]
    public let measurements: [Measurement]
    public let yDomain: ClosedRange<Double>
    public let isHeight: Bool

    public init(child: Child, measurements: [GrowthMeasurement], points: [GrowthReferencePoint], metric: String, calendar: Calendar) {
        let isHeight = metric == "height"
        self.isHeight = isHeight
        curves = points.filter { $0.metric == metric }.sorted {
            $0.sd == $1.sd ? $0.ageMonths < $1.ageMonths : $0.sd < $1.sd
        }
        self.measurements = measurements.compactMap { measurement in
            guard let raw = isHeight ? measurement.heightMillimeters : measurement.weightGrams else { return nil }
            let months = max(0, calendar.dateComponents([.month], from: child.birthDate, to: measurement.measuredAt).month ?? 0)
            return Measurement(id: measurement.id, ageMonths: Double(months), value: isHeight ? Double(raw) / 10 : Double(raw) / 1_000)
        }
        .sorted { $0.ageMonths < $1.ageMonths }
        let values = curves.map { Self.displayValue($0, isHeight: isHeight) } + self.measurements.map(\.value)
        if let minimum = values.min(), let maximum = values.max() {
            let padding = isHeight ? 2.5 : 0.75
            let step = isHeight ? 5.0 : 1.0
            let lower = floor((minimum - padding) / step) * step
            let upper = ceil((maximum + padding) / step) * step
            yDomain = lower...max(upper, lower + step)
        } else {
            yDomain = 0...1
        }
    }

    public func points(for standardDeviation: Int) -> [GrowthReferencePoint] {
        curves.filter { $0.sd == standardDeviation }
    }

    public func displayValue(_ point: GrowthReferencePoint) -> Double {
        Self.displayValue(point, isHeight: isHeight)
    }

    private static func displayValue(_ point: GrowthReferencePoint, isHeight: Bool) -> Double {
        isHeight ? Double(point.value) / 10 : Double(point.value) / 1_000
    }
}
