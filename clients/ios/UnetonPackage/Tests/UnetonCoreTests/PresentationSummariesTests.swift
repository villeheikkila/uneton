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
