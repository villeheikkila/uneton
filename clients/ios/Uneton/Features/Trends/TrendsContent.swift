import Charts
import UnetonCore
import SwiftUI

struct TrendsContent: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.unetonDisplayNow) private var displayNowOverride
    let sessions: [SleepSession]
    @Binding var range: Int
    private var now: Date { displayNowOverride ?? .now }

    var body: some View {
        let summary = SleepTrends(sessions: sessions, rangeDays: range, now: now, calendar: calendar)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Picker(String(localized: LocalizedStringResource("locRange", defaultValue: "Range", comment: "Picker title in Trends: Range")), selection: $range) {
                    Text(.loc7Days).tag(7)
                    Text(.loc30Days).tag(30)
                }
                .pickerStyle(.segmented)
                .padding(4)
                .glassEffect(.regular.tint(Color.sleepTurquoise.opacity(0.12)), in: .capsule)

                overviewCard(summary)

                HStack(spacing: 12) {
                    metricCard(
                        title: String(localized: LocalizedStringResource("locSleepSessions", defaultValue: "Sleep sessions", comment: "Message in Trends: Sleep sessions")),
                        value: "\(summary.sessionCount)",
                        detail: String(localized: LocalizedStringResource("locInThisPeriod", defaultValue: "in this period", comment: "Message in Trends: in this period")),
                        icon: "moon.zzz.fill",
                        color: .sleepBlue
                    )
                    metricCard(
                        title: String(localized: LocalizedStringResource("locDailyAverage", defaultValue: "Daily average", comment: "Message in Trends: Daily average")),
                        value: averageDuration(summary),
                        detail: String(localized: LocalizedStringResource("locTotalSleep", defaultValue: "total sleep", comment: "Message in Trends: total sleep")),
                        icon: "sparkles",
                        color: .sleepAqua
                    )
                }

                chartCard(String(localized: LocalizedStringResource("locSleepByDay", defaultValue: "Sleep by day", comment: "Message in Trends: Sleep by day")), detail: String(localized: LocalizedStringResource("locHoursLowercase", defaultValue: "hours", comment: "Message in Trends: hours"))) {
                    Chart(summary.days) { value in
                        BarMark(
                            x: .value(String(localized: LocalizedStringResource("locDay", defaultValue: "Day", comment: "Message in Trends: Day")), value.date, unit: .day),
                            y: .value(String(localized: LocalizedStringResource("locHours", defaultValue: "Hours", comment: "Message in Trends: Hours")), value.hours)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.sleepTurquoise, .sleepBlue],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .clipShape(.rect(cornerRadius: 6))
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisValueLabel(format: .dateTime.weekday(.narrow))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisGridLine().foregroundStyle(Color.sleepBlue.opacity(0.1))
                            AxisValueLabel()
                        }
                    }
                }

                chartCard(String(localized: LocalizedStringResource("locSleepRhythm", defaultValue: "Sleep rhythm", comment: "Message in Trends: Sleep rhythm")), detail: String(localized: LocalizedStringResource("locTimeOfDay", defaultValue: "time of day", comment: "Message in Trends: time of day"))) {
                    Chart(summary.completedSessions) { session in
                        BarMark(
                            xStart: .value(String(localized: LocalizedStringResource("locStartTimeAxis", defaultValue: "Start", comment: "Start is a chart axis noun for the beginning of a sleep session")), SleepTrends.minuteOfDay(session.startedAt, calendar: calendar)),
                            xEnd: .value(String(localized: LocalizedStringResource("locEnd", defaultValue: "End", comment: "End is a chart axis noun for the end of a sleep session")), SleepTrends.minuteOfDay(session.endedAt ?? now, calendar: calendar)),
                            y: .value(String(localized: LocalizedStringResource("locDay", defaultValue: "Day", comment: "Message in Trends: Day")), calendar.startOfDay(for: session.startedAt), unit: .day)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.sleepSky, .sleepTurquoise],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(.capsule)
                    }
                    .chartXScale(domain: 0...1_440)
                    .chartXAxis {
                        AxisMarks(values: [0, 360, 720, 1_080, 1_440]) { value in
                                AxisGridLine().foregroundStyle(Color.sleepBlue.opacity(0.1))
                                AxisValueLabel {
                                if let minute = value.as(Int.self) {
                                    Text(String(format: "%02d", minute / 60))
                                }
                            }
                        }
                    }
                }

                chartCard(String(localized: LocalizedStringResource("locSessionsPerDay", defaultValue: "Sessions per day", comment: "Message in Trends: Sessions per day")), detail: String(localized: LocalizedStringResource("locRhythmLowercase", defaultValue: "rhythm", comment: "Message in Trends: rhythm"))) {
                    Chart(summary.days) { value in
                        LineMark(x: .value(String(localized: LocalizedStringResource("locDay", defaultValue: "Day", comment: "Message in Trends: Day")), value.date), y: .value(String(localized: LocalizedStringResource("locNaps", defaultValue: "Naps", comment: "Message in Trends: Naps")), value.sessions))
                            .foregroundStyle(Color.sleepAqua)
                            .lineStyle(.init(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        PointMark(x: .value(String(localized: LocalizedStringResource("locDay", defaultValue: "Day", comment: "Message in Trends: Day")), value.date), y: .value(String(localized: LocalizedStringResource("locNaps", defaultValue: "Naps", comment: "Message in Trends: Naps")), value.sessions))
                            .foregroundStyle(Color.sleepAqua)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.top, 6, for: .scrollContent)
    }

    private func overviewCard(_ summary: SleepTrends) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("locSleepInsights", comment: "Text in Trends: Sleep insights")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(totalDuration(summary))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text(.locTrackedAcrossDays(String(range)))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.62))
                }
                Spacer()
                Image(systemName: "chart.xyaxis.line")
                    .font(.title2.weight(.semibold))
                    .padding(14)
                    .background(.white.opacity(0.12), in: .circle)
            }

            Chart(summary.days) { value in
                AreaMark(
                    x: .value(String(localized: LocalizedStringResource("locDay", defaultValue: "Day", comment: "Message in Trends: Day")), value.date),
                    y: .value(String(localized: LocalizedStringResource("locHours", defaultValue: "Hours", comment: "Message in Trends: Hours")), value.hours)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white.opacity(0.42), .white.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value(String(localized: LocalizedStringResource("locDay", defaultValue: "Day", comment: "Message in Trends: Day")), value.date),
                    y: .value(String(localized: LocalizedStringResource("locHours", defaultValue: "Hours", comment: "Message in Trends: Hours")), value.hours)
                )
                .foregroundStyle(.white)
                .lineStyle(.init(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 84)
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(
            LinearGradient(
                colors: [Color.sleepBlue, Color.sleepTurquoise, Color.sleepAqua],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: .rect(cornerRadius: 30)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 30)
                .stroke(.white.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: Color.sleepBlue.opacity(0.18), radius: 22, y: 10)
    }

    private func totalDuration(_ summary: SleepTrends) -> String {
        Duration.seconds(summary.totalSeconds)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private func averageDuration(_ summary: SleepTrends) -> String {
        guard !summary.days.isEmpty else { return "—" }
        return Duration.seconds(summary.averageSeconds)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private func metricCard(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(color)
                .padding(10)
                .background(color.opacity(0.12), in: .circle)
            Text(value)
                .font(.title2.monospacedDigit().weight(.bold))
                .foregroundStyle(Color.sleepInk)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular.tint(color.opacity(0.1)), in: .rect(cornerRadius: 24))
    }

    private func chartCard<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SleepSectionTitle(title: title, detail: detail)
            content().frame(height: 210)
        }
        .padding(20)
        .glassEffect(.regular.tint(Color.sleepTurquoise.opacity(0.09)), in: .rect(cornerRadius: 28))
    }
}

#if DEBUG
#Preview("Insights tab") { ScreenFixtures.preview(.insightsTab) }
#endif
