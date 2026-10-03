import Charts
import UnetonCore
import SwiftUI

struct TrendsContent: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.unetonDisplayNow) private var displayNowOverride
    @Environment(\.palette) private var palette
    let sessions: [SleepSession]
    @Binding var range: Int
    private var now: Date { displayNowOverride ?? .now }

    private var dayLabel: String { String(localized: LocalizedStringResource("locDay", defaultValue: "Day", comment: "Message in Trends: Day")) }
    private var hoursLabel: String { String(localized: LocalizedStringResource("locHours", defaultValue: "Hours", comment: "Message in Trends: Hours")) }

    var body: some View {
        let summary = SleepTrends(sessions: sessions, rangeDays: range, now: now, calendar: calendar)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TabHeader(title: LocalizedStringResource("locInsights", defaultValue: "Insights", comment: "Main navigation tab for charts and sleep summaries"))
                    Picker(String(localized: LocalizedStringResource("locRange", defaultValue: "Range", comment: "Picker title in Trends: Range")), selection: $range) {
                        Text(.loc7Days).tag(7)
                        Text(.loc30Days).tag(30)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                HStack(spacing: 10) {
                    StatTile(
                        title: LocalizedStringResource("locDailyAverage", defaultValue: "Daily average", comment: "Message in Trends: Daily average"),
                        value: averageDuration(summary),
                        detail: String(localized: LocalizedStringResource("locTotalSleep", defaultValue: "total sleep", comment: "Message in Trends: total sleep"))
                    )
                    StatTile(
                        title: LocalizedStringResource("locSleepSessions", defaultValue: "Sleep sessions", comment: "Message in Trends: Sleep sessions"),
                        value: "\(summary.sessionCount)",
                        detail: String(localized: LocalizedStringResource("locInThisPeriod", defaultValue: "in this period", comment: "Message in Trends: in this period"))
                    )
                }

                chartCard(String(localized: LocalizedStringResource("locSleepByDay", defaultValue: "Sleep by day", comment: "Message in Trends: Sleep by day")), detail: String(localized: LocalizedStringResource("locHoursLowercase", defaultValue: "hours", comment: "Message in Trends: hours"))) {
                    Chart {
                        ForEach(summary.days) { value in
                            BarMark(
                                x: .value(dayLabel, value.date, unit: .day),
                                y: .value(hoursLabel, value.hours),
                                width: .ratio(0.55)
                            )
                            .foregroundStyle(calendar.isDate(value.date, inSameDayAs: now) ? palette.accent.color.opacity(0.45) : palette.accent.color)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                        }
                        if !summary.days.isEmpty {
                            RuleMark(y: .value(hoursLabel, summary.averageSeconds / 3_600))
                                .foregroundStyle(palette.ink.color)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: range > 7 ? 5 : 1)) { _ in
                            AxisValueLabel(format: range > 7 ? .dateTime.day() : .dateTime.weekday(.abbreviated))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisGridLine().foregroundStyle(palette.inkSecondary.color.opacity(0.15))
                            AxisValueLabel()
                        }
                    }
                }

                chartCard(String(localized: LocalizedStringResource("locSleepRhythm", defaultValue: "Sleep rhythm", comment: "Message in Trends: Sleep rhythm")), detail: String(localized: LocalizedStringResource("locTimeOfDay", defaultValue: "time of day", comment: "Message in Trends: time of day"))) {
                    Chart(rhythmSegments(summary)) { segment in
                        BarMark(
                            xStart: .value(String(localized: LocalizedStringResource("locStartTimeAxis", defaultValue: "Start", comment: "Start is a chart axis noun for the beginning of a sleep session")), segment.startMinute),
                            xEnd: .value(String(localized: LocalizedStringResource("locEnd", defaultValue: "End", comment: "End is a chart axis noun for the end of a sleep session")), segment.endMinute),
                            y: .value(dayLabel, segment.day, unit: .day)
                        )
                        .foregroundStyle(segment.kind == .night ? palette.accent.color : palette.accentSoft.color)
                        .clipShape(.capsule)
                    }
                    .chartXScale(domain: 0...1_440)
                    .chartYScale(domain: rhythmDays(summary))
                    .chartXAxis {
                        AxisMarks(values: [0, 360, 720, 1_080, 1_440]) { value in
                            AxisGridLine().foregroundStyle(palette.inkSecondary.color.opacity(0.15))
                            AxisValueLabel {
                                if let minute = value.as(Int.self) {
                                    Text(String(format: "%02d", minute / 60))
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .stride(by: .day, count: range > 7 ? 5 : 1)) { _ in
                            AxisValueLabel(format: range > 7 ? .dateTime.day() : .dateTime.weekday(.abbreviated))
                        }
                    }
                }

                chartCard(String(localized: LocalizedStringResource("locSessionsPerDay", defaultValue: "Sessions per day", comment: "Message in Trends: Sessions per day")), detail: String(localized: LocalizedStringResource("locRhythmLowercase", defaultValue: "rhythm", comment: "Message in Trends: rhythm"))) {
                    Chart(summary.days) { value in
                        LineMark(x: .value(dayLabel, value.date), y: .value(String(localized: LocalizedStringResource("locNaps", defaultValue: "Naps", comment: "Message in Trends: Naps")), value.sessions))
                            .foregroundStyle(palette.accent.color)
                            .lineStyle(.init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.catmullRom)
                        PointMark(x: .value(dayLabel, value.date), y: .value(String(localized: LocalizedStringResource("locNaps", defaultValue: "Naps", comment: "Message in Trends: Naps")), value.sessions))
                            .foregroundStyle(palette.accent.color)
                            .symbolSize(50)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisGridLine().foregroundStyle(palette.inkSecondary.color.opacity(0.15))
                            AxisValueLabel()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private struct RhythmSegment: Identifiable {
        let id: String
        let day: Date
        let startMinute: Int
        let endMinute: Int
        let kind: SleepKind
    }

    /// Splits sleeps that cross midnight so each day's row shows only its own part.
    private func rhythmSegments(_ summary: SleepTrends) -> [RhythmSegment] {
        summary.completedSessions.flatMap { session -> [RhythmSegment] in
            let end = session.endedAt ?? now
            let kind = SleepKind(startedAt: session.startedAt, calendar: calendar)
            let startDay = calendar.startOfDay(for: session.startedAt)
            let startMinute = SleepTrends.minuteOfDay(session.startedAt, calendar: calendar)
            if calendar.isDate(session.startedAt, inSameDayAs: end) {
                return [RhythmSegment(id: "\(session.id)", day: startDay, startMinute: startMinute,
                    endMinute: SleepTrends.minuteOfDay(end, calendar: calendar), kind: kind)]
            }
            return [
                RhythmSegment(id: "\(session.id)-a", day: startDay, startMinute: startMinute, endMinute: 1_440, kind: kind),
                RhythmSegment(id: "\(session.id)-b", day: calendar.startOfDay(for: end), startMinute: 0,
                    endMinute: SleepTrends.minuteOfDay(end, calendar: calendar), kind: kind),
            ]
        }
    }

    /// Every day in the range gets a row, including days without sleeps.
    private func rhythmDays(_ summary: SleepTrends) -> ClosedRange<Date> {
        let first = summary.days.first?.date ?? calendar.startOfDay(for: now)
        let last = calendar.date(byAdding: .day, value: 1, to: summary.days.last?.date ?? first) ?? first
        return first...last
    }

    private func averageDuration(_ summary: SleepTrends) -> String {
        guard !summary.days.isEmpty else { return "–" }
        return SleepFormat.duration(summary.averageSeconds)
    }

    private func chartCard<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        GlassCard(cornerRadius: 30, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                SleepSectionTitle(title: title, detail: detail)
                content()
                    .frame(height: 190)
                    .foregroundStyle(palette.inkSecondary.color)
            }
        }
    }
}

#if DEBUG
#Preview("Insights tab") { ScreenFixtures.preview(.insightsTab) }
#endif
