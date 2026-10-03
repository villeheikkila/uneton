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

/// Whether a sleep reads as a nap or a night. A sleep that starts inside the night
/// window is a night; the window is generous so an early bedtime still counts.
public enum SleepKind: Sendable, Equatable {
    case nap
    case night

    public static let nightStartMinutes = 18 * 60
    public static let nightEndMinutes = 6 * 60

    public init(startedAt: Date, calendar: Calendar) {
        let minutes = SleepTrends.minuteOfDay(startedAt, calendar: calendar)
        self = minutes >= Self.nightStartMinutes || minutes < Self.nightEndMinutes ? .night : .nap
    }
}

/// Sleep history grouped the way parents read it: each day lists the sleeps that
/// ended on it, so last night appears under today in the morning.
public struct SleepDiary: Sendable {
    public struct Entry: Identifiable, Sendable {
        public var id: SleepSession.ID { session.id }
        public let session: SleepSession
        public let kind: SleepKind
        public let duration: TimeInterval
        public var isActive: Bool { session.endedAt == nil }
    }

    public struct Day: Identifiable, Sendable {
        public var id: Date { date }
        public let date: Date
        /// Newest first.
        public let entries: [Entry]
        /// Time asleep within this calendar day, including parts of sleeps that cross midnight.
        public let asleepSeconds: TimeInterval
        public let napCount: Int
    }

    public let days: [Day]

    public init(sessions: [SleepSession], now: Date, calendar: Calendar, dayLimit: Int = 14) {
        let live = sessions.filter { $0.deletedAt == nil && $0.supersededByID == nil }
        let grouped = Dictionary(grouping: live) { calendar.startOfDay(for: $0.endedAt ?? now) }
        days = grouped.keys.sorted(by: >).prefix(dayLimit).map { day in
            let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let entries = (grouped[day] ?? [])
                .sorted { $0.startedAt > $1.startedAt }
                .map { session in
                    Entry(
                        session: session,
                        kind: SleepKind(startedAt: session.startedAt, calendar: calendar),
                        duration: max(0, (session.endedAt ?? now).timeIntervalSince(session.startedAt))
                    )
                }
            let asleep = live.reduce(0.0) { total, session in
                total + max(0, min(end, session.endedAt ?? now).timeIntervalSince(max(day, session.startedAt)))
            }
            return Day(
                date: day, entries: entries, asleepSeconds: asleep,
                napCount: entries.filter { $0.kind == .nap }.count
            )
        }
    }
}
