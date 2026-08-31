import Charts
import UnetonCore
import SQLiteData
import SwiftUI

struct TimelineScreen: View {
    enum Mode: String, CaseIterable, Identifiable {
        case timeline = "Sleep"
        case trends = "Insights"
        case growth = "Growth"
        var id: Self { self }

        var systemImage: String {
            switch self {
            case .timeline: "moon.stars.fill"
            case .trends: "chart.xyaxis.line"
            case .growth: "ruler.fill"
            }
        }
    }

    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @FetchAll(SleepSession.order { $0.startedAt.desc() }) private var allSessions
    @FetchAll(GrowthMeasurement.order { $0.measuredAt.desc() }) private var allGrowthMeasurements
    @FetchAll(GrowthReferencePoint.order { $0.ageMonths }) private var allGrowthReferencePoints
    @FetchAll(SyncConflict.order { $0.createdAt.desc() }) private var allConflicts
    let family: Family
    let child: Child

    @State private var mode = Mode.timeline
    @State private var isPresentingEntry = false
    @State private var isPresentingFamily = false
    @State private var isPresentingConflicts = false
    @State private var editingSession: SleepSession?
    @State private var isPresentingGrowthEntry = false
    @State private var editingGrowthMeasurement: GrowthMeasurement?
    @Namespace private var navigationNamespace

    private var conflicts: [SyncConflict] {
        allConflicts.filter { $0.familyID == family.id }
    }

    private var sessions: [SleepSession] {
        allSessions.filter {
            $0.childID == child.id && $0.deletedAt == nil && $0.supersededByID == nil
        }
    }

    private var activeSession: SleepSession? {
        sessions.first { $0.endedAt == nil }
    }

    private var growthMeasurements: [GrowthMeasurement] {
        allGrowthMeasurements.filter { $0.childID == child.id && $0.deletedAt == nil }
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $mode) {
                ZStack {
                    SleepBackground()
                    SleepTimeline(
                        child: child,
                        sessions: sessions,
                        forecast: session.forecast?.childID == child.id ? session.forecast : nil,
                        navigationNamespace: navigationNamespace,
                        onSelectSession: { editingSession = $0 }
                    )
                }
                .tag(Mode.timeline)
                .tabItem {
                    Label(Mode.timeline.rawValue, systemImage: Mode.timeline.systemImage)
                }

                ZStack {
                    SleepBackground()
                    GrowthCard(
                        family: family,
                        child: child,
                        measurements: growthMeasurements,
                        referencePoints: allGrowthReferencePoints,
                        onAdd: { isPresentingGrowthEntry = true },
                        onSelect: { editingGrowthMeasurement = $0 }
                    )
                }
                .tag(Mode.growth)
                .tabItem {
                    Label(Mode.growth.rawValue, systemImage: Mode.growth.systemImage)
                }

                ZStack {
                    SleepBackground()
                    TrendsView(sessions: sessions)
                }
                .tag(Mode.trends)
                .tabItem {
                    Label(Mode.trends.rawValue, systemImage: Mode.trends.systemImage)
                }
            }
            .tabViewBottomAccessory(isEnabled: mode == .timeline) {
                HStack {
                    Spacer(minLength: 44)
                    bottomControl
                    Spacer(minLength: 44)
                }
                .padding(.vertical, 8)
            }
            .tint(Color.sleepIndigo)
            .navigationTitle(child.nickname)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Family", systemImage: "person.2.fill") {
                        isPresentingFamily = true
                    }
                }

                if !conflicts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Sync conflicts", systemImage: "exclamationmark.triangle.fill") {
                            isPresentingConflicts = true
                        }
                        .tint(.orange)
                    }
                }
            }
            .sheet(isPresented: $isPresentingEntry) {
                SleepEntrySheet(family: family, child: child)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isPresentingFamily) {
                FamilySharingSheet(familyID: family.id)
            }
            .sheet(isPresented: $isPresentingConflicts) {
                SyncConflictsSheet(family: family)
            }
            .sheet(item: $editingSession) { sleep in
                SleepEntrySheet(family: family, child: child, sleep: sleep)
                    .navigationTransition(.zoom(sourceID: sleep.id, in: navigationNamespace))
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isPresentingGrowthEntry) {
                GrowthEntrySheet(family: family, child: child)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $editingGrowthMeasurement) { measurement in
                GrowthEntrySheet(family: family, child: child, measurement: measurement)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await session.observeChanges(familyID: family.id)
            }
            .refreshable {
                await session.synchronize(familyID: family.id)
            }
        }
    }

    @ViewBuilder
    private var bottomControl: some View {
        if let activeSession {
            Button {
                Task {
                    await session.endSleep(familyID: family.id, sessionID: activeSession.id)
                }
            } label: {
                Label("Wake \(child.nickname)", systemImage: "sun.max.fill")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.sleepDawn)
            .disabled(session.isWorking)
            .accessibilityHint("Ends the current sleep at the present time")
        } else {
            Button {
                isPresentingEntry = true
            } label: {
                Label("Start sleep", systemImage: "moon.fill")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.sleepIndigo)
        }
    }
}

private struct SleepTimeline: View {
    let child: Child
    let sessions: [SleepSession]
    let forecast: SleepForecast?
    let navigationNamespace: Namespace.ID
    let onSelectSession: (SleepSession) -> Void

    private let calendar = Calendar.current

    private var currentPageEnd: Date {
        calendar.dateInterval(of: .hour, for: .now)?.end ?? .now
    }

    private var pageEnd: Date { currentPageEnd }

    private var pageStart: Date {
        let defaultStart = calendar.date(byAdding: .day, value: -7, to: pageEnd)!
        guard let earliest = sessions.map(\.startedAt).min() else { return defaultStart }
        let earliestHour = calendar.dateInterval(of: .hour, for: earliest)?.start ?? earliest
        return min(defaultStart, earliestHour)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 22) {
                if let latest = sessions.first {
                    SleepSummary(child: child, latest: latest, sessions: sessions, forecast: forecast)
                } else {
                    EmptySleepCard(child: child)
                }

                ContinuousSleepTimeline(
                    pageStart: pageStart,
                    pageEnd: pageEnd,
                    sessions: sessions,
                    navigationNamespace: navigationNamespace,
                    onSelectSession: onSelectSession
                )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.top, 6, for: .scrollContent)
    }

}

private struct SleepSummary: View {
    let child: Child
    let latest: SleepSession
    let sessions: [SleepSession]
    let forecast: SleepForecast?

    private var todayTotal: TimeInterval {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return sessions.reduce(0) { result, session in
            let lower = max(start, session.startedAt)
            let upper = min(end, session.endedAt ?? .now)
            return result + max(0, upper.timeIntervalSince(lower))
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(isSleeping ? "Sleeping now" : "Awake now", systemImage: isSleeping ? "moon.zzz.fill" : "sun.max.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(stateDuration(at: context.date))
                            .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                    }

                    Spacer()

                    Image(systemName: isSleeping ? "moon.stars.fill" : "cloud.sun.fill")
                        .font(.system(size: 34, weight: .medium))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.sleepInk, Color.sleepMoonlight)
                }

                if let prediction = relevantPrediction {
                    Divider()
                        .opacity(0.5)

                    HStack(spacing: 10) {
                        Image(systemName: isSleeping ? "sun.horizon.fill" : "sparkles")
                            .font(.headline)
                            .foregroundStyle(isSleeping ? Color.sleepMoonlight : Color.sleepDawn)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(isSleeping ? "Expected wake-up" : "Next sweet spot")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("Likely \(prediction.rangeStartAt.formatted(date: .omitted, time: .shortened))–\(prediction.rangeEndAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(prediction.targetAt, format: .dateTime.hour().minute())
                            .font(.title3.monospacedDigit().weight(.bold))
                    }
                }

                HStack(spacing: 12) {
                    summaryMetric("Today", value: compactDuration(todayTotal))
                    metricDivider
                    summaryMetric("Sleeps", value: "\(todaySessions.count)")
                    if let longest = todaySessions.compactMap({ session -> TimeInterval? in
                        guard let end = session.endedAt else { return nil }
                        return end.timeIntervalSince(session.startedAt)
                    }).max() {
                        metricDivider
                        summaryMetric("Longest", value: compactDuration(longest))
                    }
                }
            }
            .foregroundStyle(Color.sleepInk)
            .padding(18)
            .glassEffect(.regular.tint((isSleeping ? Color.sleepMoonlight : Color.sleepDawn).opacity(0.12)).interactive(), in: .rect(cornerRadius: 26))
        }
    }

    private var isSleeping: Bool { latest.endedAt == nil }

    private var relevantPrediction: SleepPrediction? {
        isSleeping ? forecast?.wakeEstimate : forecast?.nextSleepEstimate
    }

    private func stateDuration(at date: Date) -> String {
        let startedAt = isSleeping ? latest.startedAt : latest.endedAt ?? date
        return compactDuration(date.timeIntervalSince(startedAt))
    }

    private var todaySessions: [SleepSession] {
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return sessions.filter { $0.startedAt < end && ($0.endedAt ?? .now) > start }
    }

    private func summaryMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricDivider: some View {
        Divider()
            .opacity(0.5)
            .frame(height: 38)
    }
}

private struct EmptySleepCard: View {
    let child: Child

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color.sleepIndigo)
            Text("Ready for sweet dreams")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.sleepInk)
            Text("Start the timer when \(child.nickname) falls asleep. The rhythm will appear here over time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassEffect(.regular.tint(Color.sleepLavender.opacity(0.18)), in: .rect(cornerRadius: 28))
    }
}

private struct GrowthCard: View {
    @Environment(SessionStore.self) private var session

    let family: Family
    let child: Child
    let measurements: [GrowthMeasurement]
    let referencePoints: [GrowthReferencePoint]
    let onAdd: () -> Void
    let onSelect: (GrowthMeasurement) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Growth card", systemImage: "ruler.fill")
                        .font(.title2.weight(.bold))
                    Text("A shared record of measured height and weight. It stores observations only and does not provide medical assessment or percentiles.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .glassEffect(.regular.tint(Color.sleepMoonlight.opacity(0.12)), in: .rect(cornerRadius: 24))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Reference curves")
                        .font(.headline)
                    Picker("Reference curves", selection: Binding(
                        get: { child.growthReference },
                        set: { reference in
                            Task {
                                await session.setGrowthReference(
                                    familyID: family.id,
                                    childID: child.id,
                                    growthReference: reference
                                )
                            }
                        }
                    )) {
                        Text("Off").tag("none")
                        Text("Girl").tag("girl")
                        Text("Boy").tag("boy")
                    }
                    .pickerStyle(.segmented)
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
    private struct MeasurementPoint: Identifiable {
        let id: UUID
        let ageMonths: Double
        let value: Double
    }

    let child: Child
    let measurements: [GrowthMeasurement]
    let points: [GrowthReferencePoint]
    let metric: String

    private var isHeight: Bool { metric == "height" }
    private var title: String { isHeight ? "Height for age" : "Weight for age" }
    private var unit: String { isHeight ? "cm" : "kg" }
    private var curvePoints: [GrowthReferencePoint] { points.filter { $0.metric == metric } }
    private var standardDeviations: [Int] { [-2, -1, 0, 1, 2] }

    private var measurementPoints: [MeasurementPoint] {
        let calendar = Calendar.current
        return measurements.compactMap { measurement in
            guard let raw = isHeight ? measurement.heightMillimeters : measurement.weightGrams else { return nil }
            let months = max(0, calendar.dateComponents([.month], from: child.birthDate, to: measurement.measuredAt).month ?? 0)
            return MeasurementPoint(
                id: measurement.id,
                ageMonths: Double(months),
                value: isHeight ? Double(raw) / 10 : Double(raw) / 1_000
            )
        }
        .sorted { $0.ageMonths < $1.ageMonths }
    }

    private var yDomain: ClosedRange<Double> {
        let curveValues = curvePoints.map(displayValue)
        let values = curveValues + measurementPoints.map(\.value)
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }
        let padding = isHeight ? 2.5 : 0.75
        let step = isHeight ? 5.0 : 1.0
        let lower = floor((minimum - padding) / step) * step
        let upper = ceil((maximum + padding) / step) * step
        return lower...max(upper, lower + step)
    }

    private func points(for standardDeviation: Int) -> [GrowthReferencePoint] {
        curvePoints
            .filter { $0.sd == standardDeviation }
            .sorted { $0.ageMonths < $1.ageMonths }
    }

    private func displayValue(_ point: GrowthReferencePoint) -> Double {
        isHeight ? Double(point.value) / 10 : Double(point.value) / 1_000
    }

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
            if curvePoints.isEmpty {
                ContentUnavailableView("Reference is loading", systemImage: "arrow.triangle.2.circlepath")
                    .frame(height: 170)
            } else {
                Chart {
                    ForEach(standardDeviations, id: \.self) { standardDeviation in
                        ForEach(points(for: standardDeviation)) { point in
                            LineMark(
                                x: .value("Age", point.ageMonths),
                                y: .value(unit, displayValue(point))
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
                    ForEach(measurementPoints) { measurement in
                        LineMark(
                            x: .value("Age", measurement.ageMonths),
                            y: .value(unit, measurement.value)
                        )
                        .foregroundStyle(by: .value("Series", "Measurement"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        PointMark(x: .value("Age", measurement.ageMonths), y: .value(unit, measurement.value))
                            .foregroundStyle(by: .value("Series", "Measurement"))
                            .symbolSize(58)
                    }
                }
                .chartXAxisLabel("Age (months)")
                .chartYAxisLabel(isHeight ? "Height (cm)" : "Weight (kg)")
                .chartXScale(domain: 0...24)
                .chartYScale(domain: yDomain)
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

private struct GrowthEntrySheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let family: Family
    let child: Child
    let measurement: GrowthMeasurement?
    @State private var measuredAt: Date
    @State private var weight: String
    @State private var height: String
    @State private var note: String

    init(family: Family, child: Child, measurement: GrowthMeasurement? = nil) {
        self.family = family
        self.child = child
        self.measurement = measurement
        _measuredAt = State(initialValue: measurement?.measuredAt ?? .now)
        _weight = State(initialValue: measurement?.weightGrams.map { String(format: "%.2f", Double($0) / 1_000) } ?? "")
        _height = State(initialValue: measurement?.heightMillimeters.map { String(format: "%.1f", Double($0) / 10) } ?? "")
        _note = State(initialValue: measurement?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Measurement") {
                    DatePicker("Date", selection: $measuredAt, displayedComponents: .date)
                    TextField("Weight (kg)", text: $weight)
                        .keyboardType(.decimalPad)
                    TextField("Height (cm)", text: $height)
                        .keyboardType(.decimalPad)
                }
                Section("Note") {
                    TextField("Optional note", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    Text("Values are saved in a shared family record. They are not a medical assessment; contact your neuvola or healthcare professional with concerns.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if measurement != nil {
                    Section {
                        Button("Delete measurement", role: .destructive) {
                            Task {
                                await session.deleteGrowthMeasurement(familyID: family.id, measurementID: measurement!.id)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle(measurement == nil ? "Add measurement" : "Edit measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await session.logGrowthMeasurement(
                                familyID: family.id, childID: child.id, measurementID: measurement?.id,
                                measuredAt: measuredAt, weightGrams: grams, heightMillimeters: millimeters,
                                note: note.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            dismiss()
                        }
                    }
                    .disabled(grams == nil && millimeters == nil)
                }
            }
        }
    }

    private var grams: Int? { scaledValue(weight, multiplier: 1_000) }
    private var millimeters: Int? { scaledValue(height, multiplier: 10) }

    private func scaledValue(_ value: String, multiplier: Double) -> Int? {
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, let decimal = Double(normalized) else { return nil }
        return Int((decimal * multiplier).rounded())
    }
}

private struct ContinuousSleepTimeline: View {
    struct Period: Identifiable {
        enum State { case sleeping, awake }

        let id: String
        let state: State
        let session: SleepSession?
        let start: Date
        let end: Date
        let fullDuration: TimeInterval
        let isCurrent: Bool
    }

    let pageStart: Date
    let pageEnd: Date
    let sessions: [SleepSession]
    let navigationNamespace: Namespace.ID
    let onSelectSession: (SleepSession) -> Void

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 44

    private var hourCount: Int {
        max(1, calendar.dateComponents([.hour], from: pageStart, to: pageEnd).hour ?? 168)
    }

    private var periods: [Period] {
        let ordered = sessions.sorted { $0.startedAt < $1.startedAt }
        guard let first = ordered.first else { return [] }
        var result: [Period] = []

        for (index, session) in ordered.enumerated() {
            let sessionEnd = session.endedAt ?? .now
            appendPeriod(
                id: "sleep-\(session.id)",
                .sleeping,
                session: session,
                start: session.startedAt,
                end: sessionEnd,
                fullDuration: sessionEnd.timeIntervalSince(session.startedAt),
                isCurrent: session.endedAt == nil,
                to: &result
            )

            let awakeStart = sessionEnd
            let awakeEnd = index + 1 < ordered.count ? ordered[index + 1].startedAt : .now
            appendPeriod(
                id: "awake-\(session.id)",
                .awake,
                session: nil,
                start: awakeStart,
                end: awakeEnd,
                fullDuration: awakeEnd.timeIntervalSince(awakeStart),
                isCurrent: index == ordered.indices.last && session.endedAt != nil,
                to: &result
            )
        }

        return result.filter { $0.end > max(pageStart, first.startedAt) && $0.start < pageEnd }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SleepSectionTitle(title: "Hourly rhythm", detail: historyDetail)

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(0...hourCount, id: \.self) { hour in
                        hourMarker(hour, width: proxy.size.width)
                    }

                    ForEach(periods) { period in
                        periodBand(period, width: proxy.size.width)
                    }

                    if pageEnd >= .now && pageStart <= .now {
                        nowMarker(width: proxy.size.width)
                    }
                }
            }
            .frame(height: CGFloat(hourCount) * hourHeight)
        }
    }

    private var historyDetail: String {
        let days = max(1, Int(ceil(pageEnd.timeIntervalSince(pageStart) / 86_400)))
        return days == 1 ? "1 day" : "\(days) days"
    }

    private func hourMarker(_ hour: Int, width: CGFloat) -> some View {
        let date = calendar.date(byAdding: .hour, value: -hour, to: pageEnd)!
        let isMidnight = calendar.component(.hour, from: date) == 0

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(isMidnight ? Color.sleepIndigo.opacity(0.22) : Color.sleepInk.opacity(0.07))
                .frame(width: width - 54, height: isMidnight ? 1.5 : 0.5)
                .offset(x: 46)

            Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isMidnight ? Color.sleepIndigo : Color.secondary.opacity(0.46))
                .frame(width: 48, alignment: .trailing)
                .offset(x: -16, y: -7)

            if isMidnight {
                Text(date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.sleepIndigo)
                    .offset(x: 52, y: -9)
            }
        }
        .offset(y: CGFloat(hour) * hourHeight)
    }

    private func periodBand(_ period: Period, width: CGFloat) -> some View {
        let clippedStart = max(period.start, pageStart)
        let clippedEnd = min(period.end, pageEnd)
        let y = pageEnd.timeIntervalSince(clippedEnd) / 3_600 * hourHeight
        let height = max(clippedEnd.timeIntervalSince(clippedStart) / 3_600 * hourHeight, 3)
        let sleeping = period.state == .sleeping

        let band = Button {
            if let session = period.session { onSelectSession(session) }
        } label: {
            ZStack(alignment: .topLeading) {
                if sleeping {
                    RoundedRectangle(cornerRadius: min(12, height / 2))
                        .fill(Color.sleepIndigo.opacity(0.84))
                } else {
                    Rectangle()
                        .fill(.clear)

                    Rectangle()
                        .fill(Color.sleepDawn.opacity(0.3))
                        .frame(width: 2)
                }

                if height >= 40 {
                    HStack(spacing: 8) {
                        Image(systemName: sleeping ? "moon.fill" : "sun.max.fill")
                            .font(.caption.weight(.bold))
                        Text(sleeping ? "Sleep" : "Awake")
                            .font(.caption.weight(.semibold))
                        Text(duration(period.fullDuration))
                            .font(.caption.monospacedDigit().weight(.bold))
                        if period.isCurrent {
                            Circle()
                                .fill(sleeping ? Color.sleepMoonlight : Color.sleepDawn)
                                .frame(width: 6, height: 6)
                        }

                        Spacer(minLength: 6)

                        Text(periodRange(period))
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(sleeping ? .white.opacity(0.72) : Color.sleepInk.opacity(0.48))
                    }
                    .foregroundStyle(sleeping ? .white : Color.sleepInk.opacity(0.76))
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(period.session == nil)
        .frame(width: width - 58, height: height, alignment: .topLeading)

        return transitionSource(
            band,
            session: period.session,
            cornerRadius: min(12, height / 2)
        )
        .offset(x: 50, y: y)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(sleeping ? "Sleep" : "Awake"), \(duration(period.fullDuration)), from \(period.start.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityHint(sleeping ? "Opens this sleep for editing" : "")
    }

    @ViewBuilder
    private func transitionSource(
        _ content: some View,
        session: SleepSession?,
        cornerRadius: CGFloat
    ) -> some View {
        if let session {
            content.matchedTransitionSource(id: session.id, in: navigationNamespace) { source in
                source
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .background(Color.sleepIndigo.opacity(0.84))
            }
        } else {
            content
        }
    }

    private func nowMarker(width: CGFloat) -> some View {
        let y = pageEnd.timeIntervalSince(.now) / 3_600 * hourHeight
        return ZStack(alignment: .topTrailing) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.sleepDawn)
                    .frame(width: 9, height: 9)
                Rectangle()
                    .fill(Color.sleepDawn)
                    .frame(height: 2)
            }

            Text("NOW")
                .font(.caption2.weight(.black))
                .foregroundStyle(Color.sleepDawn)
                .padding(.horizontal, 6)
                .background(Color.sleepCanvas.opacity(0.94), in: .capsule)
                .offset(y: -14)
        }
        .frame(width: width - 52)
        .offset(x: 42, y: y - 4)
    }

    private func appendPeriod(
        id: String,
        _ state: Period.State,
        session: SleepSession?,
        start: Date,
        end: Date,
        fullDuration: TimeInterval,
        isCurrent: Bool,
        to periods: inout [Period]
    ) {
        guard end > pageStart, start < pageEnd, end > start else { return }
        periods.append(Period(id: id, state: state, session: session, start: start, end: end, fullDuration: fullDuration, isCurrent: isCurrent))
    }

    private func duration(_ seconds: TimeInterval) -> String {
        compactDuration(seconds)
    }

    private func periodRange(_ period: Period) -> String {
        let start = period.start.formatted(date: .omitted, time: .shortened)
        let end = period.isCurrent ? "now" : period.end.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }
}

private func compactDuration(_ seconds: TimeInterval) -> String {
    Duration.seconds(max(0, seconds))
        .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
}

extension Color {
    static let sleepInk = Color(red: 0.09, green: 0.10, blue: 0.22)
    static let sleepIndigo = Color(red: 0.32, green: 0.30, blue: 0.78)
    static let sleepLavender = Color(red: 0.63, green: 0.55, blue: 0.91)
    static let sleepMoonlight = Color(red: 0.43, green: 0.79, blue: 0.91)
    static let sleepDawn = Color(red: 0.98, green: 0.66, blue: 0.50)
    static let sleepCanvas = Color(red: 0.88, green: 0.96, blue: 0.97)
}

struct SleepBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            GeometryReader { proxy in
                Rectangle()
                    .fill(.white)
                    .colorEffect(
                        ShaderLibrary.sleepClouds(
                            .float(
                                reduceMotion
                                    ? 0
                                    : Float(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 600))
                            ),
                            .float2(proxy.size)
                        )
                    )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct SleepSectionTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.sleepInk)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
