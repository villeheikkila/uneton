import UnetonCore
import SQLiteData
import SwiftUI

struct TimelineScreen: View {
    enum Mode: String, CaseIterable, Identifiable {
        case timeline = "Sleep"
        case trends = "Insights"
        var id: Self { self }

        var systemImage: String {
            switch self {
            case .timeline: "moon.stars.fill"
            case .trends: "chart.xyaxis.line"
            }
        }
    }

    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @FetchAll(SleepSession.order { $0.startedAt.desc() }) private var allSessions
    @FetchAll(SyncConflict.order { $0.createdAt.desc() }) private var allConflicts
    let family: Family
    let child: Child

    @State private var mode = Mode.timeline
    @State private var isPresentingEntry = false
    @State private var isPresentingFamily = false
    @State private var isPresentingConflicts = false
    @State private var editingSession: SleepSession?
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

    var body: some View {
        NavigationStack {
            ZStack {
                SleepBackground()

                Group {
                    switch mode {
                    case .timeline:
                        SleepTimeline(
                            child: child,
                            sessions: sessions,
                            forecast: session.forecast?.childID == child.id ? session.forecast : nil,
                            navigationNamespace: navigationNamespace,
                            onSelectSession: { editingSession = $0 }
                        )
                    case .trends:
                        TrendsView(sessions: sessions)
                    }
                }
                .id(mode)
                .transition(.blurReplace)
            }
            .navigationTitle(child.nickname)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Family", systemImage: "person.2.fill") {
                        isPresentingFamily = true
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !conflicts.isEmpty {
                        Button("Sync conflicts", systemImage: "exclamationmark.triangle.fill") {
                            isPresentingConflicts = true
                        }
                        .tint(.orange)
                    }

                    Button(mode == .timeline ? "Show insights" : "Show timeline", systemImage: mode == .timeline ? "chart.xyaxis.line" : "moon.stars.fill") {
                        withAnimation(.snappy) { mode = mode == .timeline ? .trends : .timeline }
                    }
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityValue(mode == .timeline ? "Timeline selected" : "Insights selected")
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer(minLength: 44)
                    bottomControl
                    Spacer(minLength: 44)
                }
                .padding(.vertical, 8)
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
