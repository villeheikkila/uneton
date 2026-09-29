import Charts
import SwiftUI
import UnetonCore

struct GrowthContent: View {
    let child: Child
    let measurements: [GrowthMeasurement]
    let referencePoints: [GrowthReferencePoint]
    let onAdd: () -> Void
    let onSelect: (GrowthMeasurement) -> Void
    let onReferenceChanged: (String) -> Void

    var body: some View {
        GrowthCard(child: child, measurements: measurements, referencePoints: referencePoints,
            onAdd: onAdd, onSelect: onSelect, onReferenceChanged: onReferenceChanged)
    }
}

private struct GrowthCard: View {
    let child: Child
    let measurements: [GrowthMeasurement]
    let referencePoints: [GrowthReferencePoint]
    let onAdd: () -> Void
    let onSelect: (GrowthMeasurement) -> Void
    let onReferenceChanged: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Growth", systemImage: "ruler.fill")
                        .font(.title2.weight(.bold))
                    Text("Keep height and weight in one place and see how they change over time.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .glassEffect(.regular.tint(Color.sleepMoonlight.opacity(0.12)), in: .rect(cornerRadius: 24))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Reference curves")
                        .font(.headline)
                    HStack(spacing: 8) {
                        referenceButton("Off", value: "none")
                        referenceButton("Girl", value: "girl")
                        referenceButton("Boy", value: "boy")
                    }
                    Text("The selected Finnish reference is a visual guide only, not a medical assessment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))

                if child.growthReference != "none" {
                    GrowthReferenceCharts(
                        child: child,
                        measurements: measurements,
                        points: referencePoints.filter { $0.reference == child.growthReference }
                    )
                }

                Button(action: onAdd) {
                    Label("Add measurement", systemImage: "plus.circle.fill")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.glassProminent)
                .tint(Color.sleepIndigo)

                if measurements.isEmpty {
                    ContentUnavailableView(
                        "No measurements yet",
                        systemImage: "heart.text.square",
                        description: Text("Add the measurements from a neuvola visit or home scale.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    ForEach(measurements) { measurement in
                        Button { onSelect(measurement) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "cross.case.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color.sleepIndigo)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(measurement.measuredAt, format: .dateTime.year().month(.wide).day())
                                        .font(.headline)
                                    Text(measurementValues(measurement))
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    if !measurement.note.isEmpty {
                                        Text(measurement.note)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(16)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func measurementValues(_ measurement: GrowthMeasurement) -> String {
        [
            measurement.weightGrams.map { String(format: "%.2f kg", Double($0) / 1_000) },
            measurement.heightMillimeters.map { String(format: "%.1f cm", Double($0) / 10) },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private func referenceButton(_ title: String, value: String) -> some View {
        Button(title) { onReferenceChanged(value) }
            .buttonStyle(.bordered)
            .tint(child.growthReference == value ? Color.sleepIndigo : .secondary)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(child.growthReference == value ? .isSelected : [])
    }
}

private struct GrowthReferenceCharts: View {
    let child: Child
    let measurements: [GrowthMeasurement]
    let points: [GrowthReferencePoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label("Growth curves", systemImage: "chart.xyaxis.line")
                    .font(.title3.weight(.bold))
                Spacer()
                Text("0–2 years")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text("Finnish reference curves with your recorded measurements.")
                .font(.caption)
                .foregroundStyle(.secondary)
            GrowthReferenceChart(child: child, measurements: measurements, points: points, metric: "height")
            GrowthReferenceChart(child: child, measurements: measurements, points: points, metric: "weight")
        }
        .padding(18)
        .glassEffect(.regular.tint(Color.sleepMoonlight.opacity(0.08)), in: .rect(cornerRadius: 24))
    }
}

private struct GrowthReferenceChart: View {
    @Environment(\.calendar) private var calendar
    let child: Child
    let measurements: [GrowthMeasurement]
    let points: [GrowthReferencePoint]
    let metric: String

    private var isHeight: Bool { metric == "height" }
    private var title: String { isHeight ? "Height for age" : "Weight for age" }
    private var unit: String { isHeight ? "cm" : "kg" }
    private var chartData: GrowthChartData {
        GrowthChartData(child: child, measurements: measurements, points: points, metric: metric, calendar: calendar)
    }
    private var standardDeviations: [Int] { [-2, -1, 0, 1, 2] }

    private func curveColor(for standardDeviation: Int) -> Color {
        standardDeviation == 0
            ? Color(red: 0.88, green: 0.16, blue: 0.52)
            : Color(red: 0.97, green: 0.35, blue: 0.66).opacity(0.72)
    }

    private func curveLabel(for standardDeviation: Int) -> String {
        standardDeviation == 0 ? "0 SD" : "\(standardDeviation > 0 ? "+" : "")\(standardDeviation) SD"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(unit)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.sleepIndigo)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.sleepMoonlight.opacity(0.16), in: .capsule)
            }
            if chartData.curves.isEmpty {
                ContentUnavailableView("Reference is loading", systemImage: "arrow.triangle.2.circlepath")
                    .frame(height: 170)
            } else {
                Chart {
                    ForEach(standardDeviations, id: \.self) { standardDeviation in
                        ForEach(chartData.points(for: standardDeviation)) { point in
                            LineMark(
                                x: .value("Age", point.ageMonths),
                                y: .value(unit, chartData.displayValue(point))
                            )
                            .foregroundStyle(by: .value("Series", curveLabel(for: standardDeviation)))
                            .lineStyle(
                                StrokeStyle(
                                    lineWidth: standardDeviation == 0 ? 2.5 : 1.15,
                                    dash: abs(standardDeviation) == 2 ? [3, 3] : []
                                )
                            )
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    ForEach(chartData.measurements) { measurement in
                        LineMark(
                            x: .value("Age", measurement.ageMonths),
                            y: .value(unit, measurement.value)
                        )
                        .foregroundStyle(by: .value("Series", "Measurement"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    ForEach(chartData.measurements) { measurement in
                        PointMark(x: .value("Age", measurement.ageMonths), y: .value(unit, measurement.value))
                            .foregroundStyle(by: .value("Series", "Measurement"))
                            .symbolSize(58)
                    }
                }
                .chartXAxisLabel("Age (months)")
                .chartYAxisLabel(isHeight ? "Height (cm)" : "Weight (kg)")
                .chartXScale(domain: 0...24)
                .chartYScale(domain: chartData.yDomain)
                .chartForegroundStyleScale([
                    curveLabel(for: -2): curveColor(for: -2),
                    curveLabel(for: -1): curveColor(for: -1),
                    curveLabel(for: 0): curveColor(for: 0),
                    curveLabel(for: 1): curveColor(for: 1),
                    curveLabel(for: 2): curveColor(for: 2),
                    "Measurement": Color.sleepIndigo,
                ])
                .chartXAxis {
                    AxisMarks(values: .stride(by: 3)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.8))
                            .foregroundStyle(Color.sleepMoonlight.opacity(0.42))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                        AxisValueLabel {
                            if let month = value.as(Int.self) {
                                Text(month == 0 ? "Birth" : "\(month)m")
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.8))
                            .foregroundStyle(Color.sleepMoonlight.opacity(0.42))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                        AxisValueLabel()
                    }
                }
                .chartPlotStyle { content in
                    content
                        .background(Color.sleepMoonlight.opacity(0.07))
                        .border(Color.sleepMoonlight.opacity(0.55), width: 1)
                }
                .chartLegend(.hidden)
                .frame(height: isHeight ? 245 : 205)

                HStack(spacing: 10) {
                    ForEach(standardDeviations, id: \.self) { standardDeviation in
                        HStack(spacing: 4) {
                            Capsule()
                                .fill(curveColor(for: standardDeviation))
                                .frame(width: 18, height: standardDeviation == 0 ? 3 : 1.5)
                            Text(curveLabel(for: standardDeviation))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

}
