import Charts
import SwiftUI
import UnetonCore

struct GrowthContent: View {
    @Environment(\.palette) private var palette
    @Environment(\.calendar) private var calendar
    let child: Child
    let measurements: [GrowthMeasurement]
    let referencePoints: [GrowthReferencePoint]
    let onAdd: () -> Void
    let onSelect: (GrowthMeasurement) -> Void
    let onReferenceChanged: (String) -> Void

    @State private var metric = "weight"

    private var latestWeight: GrowthMeasurement? {
        measurements.filter { $0.weightGrams != nil }.max { $0.measuredAt < $1.measuredAt }
    }

    private var latestHeight: GrowthMeasurement? {
        measurements.filter { $0.heightMillimeters != nil }.max { $0.measuredAt < $1.measuredAt }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                TabHeader(title: LocalizedStringResource("locGrowth", defaultValue: "Growth", comment: "Label in Timeline: Growth"))

                if measurements.isEmpty {
                    GlassCard {
                        ContentUnavailableView {
                            Label(LocalizedStringResource("locNoMeasurementsYet", defaultValue: "No measurements yet", comment: "Text in Timeline: No measurements yet"), systemImage: "ruler")
                        } description: {
                            Text("locAddTheMeasurementsFromANeuvolaVisitOrHomeScale", comment: "Text in Timeline: Add the measurements from a neuvola visit or home scale.")
                        } actions: {
                            Button(LocalizedStringResource("locAddMeasurement", defaultValue: "Add measurement", comment: "Label in Timeline: Add measurement"), systemImage: "plus", action: onAdd)
                                .buttonStyle(.glassProminent)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        StatTile(
                            title: LocalizedStringResource("locWeight", defaultValue: "Weight", comment: "Growth tile title for the latest weight"),
                            value: latestWeight?.weightGrams.map(GrowthFormat.weight) ?? "–",
                            detail: latestWeight.map { $0.measuredAt.formatted(.dateTime.day().month()) }
                        )
                        StatTile(
                            title: LocalizedStringResource("locHeight", defaultValue: "Height", comment: "Growth tile title for the latest height"),
                            value: latestHeight?.heightMillimeters.map(GrowthFormat.height) ?? "–",
                            detail: latestHeight.map { $0.measuredAt.formatted(.dateTime.day().month()) }
                        )
                    }
                }

                GlassCard(cornerRadius: 30, padding: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(LocalizedStringResource("locReferenceCurves", defaultValue: "Reference curves", comment: "Picker for the Finnish growth reference"), selection: Binding(
                            get: { child.growthReference },
                            set: { onReferenceChanged($0) }
                        )) {
                            Text(LocalizedStringResource("locOff", defaultValue: "Off", comment: "Button title in Timeline: Off")).tag("none")
                            Text(LocalizedStringResource("locGirl", defaultValue: "Girl", comment: "Button title in Timeline: Girl")).tag("girl")
                            Text(LocalizedStringResource("locBoy", defaultValue: "Boy", comment: "Button title in Timeline: Boy")).tag("boy")
                        }
                        .pickerStyle(.segmented)

                        if child.growthReference != "none" {
                            Picker(LocalizedStringResource("locGrowthCurves", defaultValue: "Growth curves", comment: "Label in Timeline: Growth curves"), selection: $metric) {
                                Text(LocalizedStringResource("locWeightForAge", defaultValue: "Weight for age", comment: "Message in Timeline: Weight for age")).tag("weight")
                                Text(LocalizedStringResource("locHeightForAge", defaultValue: "Height for age", comment: "Message in Timeline: Height for age")).tag("height")
                            }
                            .pickerStyle(.segmented)

                            GrowthReferenceChart(
                                child: child,
                                measurements: measurements,
                                points: referencePoints.filter { $0.reference == child.growthReference },
                                metric: metric
                            )
                        }

                        Text("locTheSelectedFinnishReferenceIsAVisualGuideOnlyNotAMedicalAssessment", comment: "Text in Timeline: The selected Finnish reference is a visual guide only, not a medical assessment.")
                            .font(.soft(12, weight: .semibold))
                            .foregroundStyle(palette.inkSecondary.color)
                    }
                }

                if !measurements.isEmpty {
                    GlassCard(cornerRadius: 26, padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(measurements.sorted { $0.measuredAt > $1.measuredAt }) { measurement in
                                DiaryRow(
                                    title: measurement.measuredAt.formatted(.dateTime.day().month(.wide).year()),
                                    subtitle: measurement.note.isEmpty ? nil : measurement.note,
                                    value: GrowthFormat.values(measurement),
                                    marker: palette.accent.color
                                ) { onSelect(measurement) }
                                if measurement.id != measurements.min(by: { $0.measuredAt < $1.measuredAt })?.id {
                                    Divider().padding(.leading, 34)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }
}

enum GrowthFormat {
    static func weight(_ grams: Int) -> String {
        String(format: "%.2f kg", locale: .current, Double(grams) / 1_000)
    }

    static func height(_ millimeters: Int) -> String {
        String(format: "%.1f cm", locale: .current, Double(millimeters) / 10)
    }

    static func values(_ measurement: GrowthMeasurement) -> String {
        [measurement.weightGrams.map(weight), measurement.heightMillimeters.map(height)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

private struct GrowthReferenceChart: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.palette) private var palette
    let child: Child
    let measurements: [GrowthMeasurement]
    let points: [GrowthReferencePoint]
    let metric: String

    private var isHeight: Bool { metric == "height" }
    private var unit: String { isHeight ? "cm" : "kg" }
    private var chartData: GrowthChartData {
        GrowthChartData(child: child, measurements: measurements, points: points, metric: metric, calendar: calendar)
    }
    private var standardDeviations: [Int] { [-2, -1, 0, 1, 2] }
    private var ageLabel: String { String(localized: LocalizedStringResource("locAge", defaultValue: "Age", comment: "Message in Timeline: Age")) }
    private var seriesLabel: String { String(localized: LocalizedStringResource("locSeries", defaultValue: "Series", comment: "Message in Timeline: Series")) }
    private var measurementLabel: String { String(localized: LocalizedStringResource("locMeasurement", defaultValue: "Measurement", comment: "Message in Timeline: Measurement")) }

    private func curveLabel(for standardDeviation: Int) -> String {
        standardDeviation == 0 ? "0 SD" : "\(standardDeviation > 0 ? "+" : "")\(standardDeviation) SD"
    }

    var body: some View {
        if chartData.curves.isEmpty {
            ContentUnavailableView(LocalizedStringResource("locReferenceIsLoading", defaultValue: "Reference is loading", comment: "Text in Timeline: Reference is loading"), systemImage: "arrow.triangle.2.circlepath")
                .frame(height: 200)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Chart {
                    ForEach(standardDeviations, id: \.self) { standardDeviation in
                        ForEach(chartData.points(for: standardDeviation)) { point in
                            LineMark(x: .value(ageLabel, point.ageMonths), y: .value(unit, chartData.displayValue(point)))
                                .foregroundStyle(by: .value(seriesLabel, curveLabel(for: standardDeviation)))
                                .lineStyle(StrokeStyle(lineWidth: standardDeviation == 0 ? 2 : 1, dash: standardDeviation == 0 ? [4, 4] : []))
                                .interpolationMethod(.catmullRom)
                        }
                    }
                    ForEach(chartData.measurements) { measurement in
                        LineMark(x: .value(ageLabel, measurement.ageMonths), y: .value(unit, measurement.value))
                            .foregroundStyle(by: .value(seriesLabel, measurementLabel))
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                        PointMark(x: .value(ageLabel, measurement.ageMonths), y: .value(unit, measurement.value))
                            .foregroundStyle(by: .value(seriesLabel, measurementLabel))
                            .symbolSize(70)
                    }
                }
                .chartXScale(domain: 0...24)
                .chartYScale(domain: chartData.yDomain)
                .chartForegroundStyleScale([
                    curveLabel(for: -2): palette.accentSoft.color.opacity(0.7),
                    curveLabel(for: -1): palette.accentSoft.color,
                    curveLabel(for: 0): palette.inkSecondary.color,
                    curveLabel(for: 1): palette.accentSoft.color,
                    curveLabel(for: 2): palette.accentSoft.color.opacity(0.7),
                    measurementLabel: palette.accent.color,
                ])
                .chartXAxis {
                    AxisMarks(values: .stride(by: 3)) { value in
                        AxisGridLine().foregroundStyle(palette.inkSecondary.color.opacity(0.15))
                        AxisValueLabel {
                            if let month = value.as(Int.self) {
                                Text(month == 0 ? LocalizedStringResource("locBirth", defaultValue: "Birth", comment: "Growth chart age axis, with age in months") : .locMonthShort(String(month)))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(palette.inkSecondary.color.opacity(0.15))
                        AxisValueLabel()
                    }
                }
                .chartLegend(.hidden)
                .frame(height: isHeight ? 240 : 210)

                HStack(spacing: 14) {
                    legend(color: palette.accent.color, label: measurementLabel)
                    legend(color: palette.inkSecondary.color, label: curveLabel(for: 0), dashed: true)
                    legend(color: palette.accentSoft.color, label: "±1–2 SD")
                }
                .font(.soft(12, weight: .bold))
                .foregroundStyle(palette.inkSecondary.color)
            }
        }
    }

    private func legend(color: Color, label: String, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, dash: dashed ? [3, 2] : []))
                .frame(width: 16, height: 2)
            Text(label)
        }
    }
}
