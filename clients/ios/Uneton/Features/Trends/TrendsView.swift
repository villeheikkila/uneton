import Charts
import UnetonCore
import SwiftUI

struct TrendsView: View {
    let sessions: [SleepSession]
    @State private var range = 7

    private var daily: [DailySleep] {
        let calendar = Calendar.current
        return (0..<range).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: .now)),
                  let end = calendar.date(byAdding: .day, value: 1, to: day)
            else { return nil }
            let matching = sessions.filter { $0.startedAt < end && ($0.endedAt ?? .now) > day }
            let seconds = matching.reduce(0.0) { result, session in
                result + max(0, min(end, session.endedAt ?? .now).timeIntervalSince(max(day, session.startedAt)))
            }
            return DailySleep(day: day, hours: seconds / 3_600, naps: matching.count)
        }
    }

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
                        value: "\(daily.reduce(0) { $0 + $1.naps })",
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
                    Chart(daily) { value in
                        BarMark(
                            x: .value("Day", value.day, unit: .day),
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
                    Chart(sessionsInRange) { session in
                        BarMark(
                            xStart: .value("Start", minuteOfDay(session.startedAt)),
                            xEnd: .value("End", minuteOfDay(session.endedAt ?? .now)),
                            y: .value("Day", Calendar.current.startOfDay(for: session.startedAt), unit: .day)
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
                    Chart(daily) { value in
                        LineMark(x: .value("Day", value.day), y: .value("Naps", value.naps))
                            .foregroundStyle(Color.sleepDawn)
                            .lineStyle(.init(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        PointMark(x: .value("Day", value.day), y: .value("Naps", value.naps))
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

            Chart(daily) { value in
                AreaMark(
                    x: .value("Day", value.day),
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
                    x: .value("Day", value.day),
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
        Duration.seconds(daily.reduce(0) { $0 + $1.hours * 3_600 })
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private var averageDuration: String {
        guard !daily.isEmpty else { return "—" }
        let seconds = daily.reduce(0) { $0 + $1.hours * 3_600 } / Double(daily.count)
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private var sessionsInRange: [SleepSession] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -range, to: .now) ?? .distantPast
        return sessions.filter { $0.startedAt >= cutoff && $0.endedAt != nil }
    }

    private func minuteOfDay(_ date: Date) -> Int {
        Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
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

private struct DailySleep: Identifiable {
    var id: Date { day }
    let day: Date
    let hours: Double
    let naps: Int
}
