import Foundation
import Testing
@testable import UnetonCore

struct PresentationSummariesTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func `sleep crossing midnight is split across days`() {
        let now = Date(timeIntervalSince1970: 1_790_035_200)
        let midnight = calendar.startOfDay(for: now)
        let sleep = ModelFixtures.sleep(
            startedAt: midnight.addingTimeInterval(-3_600),
            endedAt: midnight.addingTimeInterval(3_600)
        )
        let trends = SleepTrends(sessions: [sleep], rangeDays: 2, now: now, calendar: calendar)
        #expect(trends.days.map(\.hours) == [1, 1])
        #expect(trends.sessionCount == 2)
        #expect(trends.totalSeconds == 7_200)
        #expect(trends.averageSeconds == 3_600)
    }

    @Test func `growth chart converts measurements and includes them in scale`() {
        let birthDate = calendar.startOfDay(for: ModelFixtures.now)
        let child = ModelFixtures.child(birthDate: birthDate)
        let measuredAt = calendar.date(byAdding: .month, value: 6, to: birthDate)!
        let measurement = ModelFixtures.growth(measuredAt: measuredAt, heightMillimeters: 720)
        let reference = GrowthReferencePoint(reference: "girl", metric: "height", ageMonths: 6, sd: 0, value: 680)
        let chart = GrowthChartData(
            child: child, measurements: [measurement], points: [reference],
            metric: "height", calendar: calendar
        )
        #expect(chart.measurements.first?.ageMonths == 6)
        #expect(chart.measurements.first?.value == 72)
        #expect(chart.points(for: 0).count == 1)
        #expect(chart.yDomain.contains(72))
    }
}

struct SleepDiaryTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func `night belongs to the morning it ended and counts on both days`() {
        let night = ModelFixtures.sleep(id: .init(), startedAt: at(1, 19, 30), endedAt: at(2, 6, 40))
        let nap = ModelFixtures.sleep(id: .init(), startedAt: at(2, 8, 45), endedAt: at(2, 10))
        let diary = SleepDiary(sessions: [night, nap], now: at(2, 11, 42), calendar: calendar)
        #expect(diary.days.count == 1)
        let today = diary.days[0]
        #expect(today.entries.map(\.kind) == [.nap, .night])
        #expect(today.napCount == 1)
        #expect(today.asleepSeconds == (6 * 60 + 40 + 75) * 60)
    }

    @Test func `active sleep is listed under today with a running duration`() {
        let active = ModelFixtures.sleep(id: .init(), startedAt: at(2, 12, 28), endedAt: nil)
        let diary = SleepDiary(sessions: [active], now: at(2, 13, 20), calendar: calendar)
        #expect(diary.days.first?.entries.first?.isActive == true)
        #expect(diary.days.first?.entries.first?.duration == TimeInterval(52 * 60))
    }

    @Test func `sleep kind uses the night window`() {
        #expect(SleepKind(startedAt: at(2, 19, 30), calendar: calendar) == .night)
        #expect(SleepKind(startedAt: at(2, 3), calendar: calendar) == .night)
        #expect(SleepKind(startedAt: at(2, 12, 28), calendar: calendar) == .nap)
    }
}
