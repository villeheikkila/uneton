import Charts
import UnetonCore
import SwiftUI

struct TrendsView: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.unetonDisplayNow) private var displayNowOverride
    let sessions: [SleepSession]
    @Binding var range: Int
    private var now: Date { displayNowOverride ?? .now }
    private var summary: SleepTrends { SleepTrends(sessions: sessions, rangeDays: range, now: now, calendar: calendar) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Picker("Range", selection: $range) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .padding(4)
                .glassEffect(.regular.tint(Color.sleepLavender.opacity(0.12)), in: .capsule)

                overviewCard

                HStack(spacing: 12) {
                    metricCard(
                        title: "Sleep sessions",
                        value: "\(summary.sessionCount)",
                        detail: "in this period",
                        icon: "moon.zzz.fill",
                        color: .sleepIndigo
                    )
                    metricCard(
                        title: "Daily average",
                        value: averageDuration,
                        detail: "total sleep",
                        icon: "sparkles",
                        color: .sleepDawn
                    )
                }

                chartCard("Sleep by day", detail: "hours") {
                    Chart(summary.days) { value in
                        BarMark(
                            x: .value("Day", value.date, unit: .day),
                            y: .value("Hours", value.hours)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.sleepLavender, .sleepIndigo],
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
                            AxisGridLine().foregroundStyle(Color.sleepIndigo.opacity(0.1))
                            AxisValueLabel()
                        }
                    }
                }

                chartCard("Sleep rhythm", detail: "time of day") {
                    Chart(summary.completedSessions) { session in
                        BarMark(
                            xStart: .value("Start", SleepTrends.minuteOfDay(session.startedAt, calendar: calendar)),
                            xEnd: .value("End", SleepTrends.minuteOfDay(session.endedAt ?? now, calendar: calendar)),
                            y: .value("Day", calendar.startOfDay(for: session.startedAt), unit: .day)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.sleepMoonlight, .sleepLavender],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(.capsule)
                    }
                    .chartXScale(domain: 0...1_440)
                    .chartXAxis {
                        AxisMarks(values: [0, 360, 720, 1_080, 1_440]) { value in
                                AxisGridLine().foregroundStyle(Color.sleepIndigo.opacity(0.1))
                                AxisValueLabel {
                                if let minute = value.as(Int.self) {
                                    Text(String(format: "%02d", minute / 60))
                                }
                            }
                        }
                    }
                }

                chartCard("Sessions per day", detail: "rhythm") {
                    Chart(summary.days) { value in
                        LineMark(x: .value("Day", value.date), y: .value("Naps", value.sessions))
                            .foregroundStyle(Color.sleepDawn)
                            .lineStyle(.init(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        PointMark(x: .value("Day", value.date), y: .value("Naps", value.sessions))
                            .foregroundStyle(Color.sleepDawn)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.top, 6, for: .scrollContent)
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sleep insights")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(totalDuration)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text("tracked across \(range) days")
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
                    x: .value("Day", value.date),
                    y: .value("Hours", value.hours)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white.opacity(0.42), .white.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Day", value.date),
                    y: .value("Hours", value.hours)
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
                colors: [Color.sleepIndigo, Color.sleepLavender, Color.sleepMoonlight.opacity(0.9)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: .rect(cornerRadius: 30)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 30)
                .stroke(.white.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: Color.sleepIndigo.opacity(0.18), radius: 22, y: 10)
    }

    private var totalDuration: String {
        Duration.seconds(summary.totalSeconds)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private var averageDuration: String {
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
        .glassEffect(.regular.tint(Color.sleepLavender.opacity(0.09)), in: .rect(cornerRadius: 28))
    }
}

#if DEBUG
#Preview("Insights tab") { ScreenFixtures.preview(.insightsTab) }
#endif
