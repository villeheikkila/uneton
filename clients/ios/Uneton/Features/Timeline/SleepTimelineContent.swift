import SwiftUI
import UnetonCore
import UnetonTheme

/// The sleep tab: a big timer for the current state, one panel with the next
/// estimate and the main action, and the diary below it.
struct SleepHome: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.unetonDisplayNow) private var displayNowOverride
    @Environment(\.palette) private var palette
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.sleepHomeStartsAtDiary) private var startsAtDiary
    let childName: String
    let sessions: [SleepSession]
    let forecast: SleepForecast?
    let isWaking: Bool
    let onStart: () -> Void
    let onWake: (SleepSession.ID) -> Void
    let onSelectSession: (SleepSession) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = displayNowOverride ?? context.date
            let state = SleepHomeState(sessions: sessions, forecast: forecast, now: now, calendar: calendar,
                timeStyle: Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone))
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 28) {
                        VStack(spacing: 0) {
                            Spacer(minLength: 24)
                            hero(state)
                            Spacer(minLength: 24)
                            panel(state)
                        }
                        .frame(minHeight: proxy.size.height - 12)

                        if !state.diary.days.isEmpty {
                            SleepDiaryList(state: state, onSelectSession: onSelectSession)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(startsAtDiary ? .bottom : .top)
            }
        }
    }

    @ViewBuilder
    private func hero(_ state: SleepHomeState) -> some View {
        if let since = state.since {
            VStack(spacing: 6) {
                Label {
                    Text(state.heroLabel)
                } icon: {
                    Image(systemName: state.active == nil ? "sun.max.fill" : "moon.fill")
                }
                .font(.soft(19, weight: .bold))
                .foregroundStyle(palette.inkSecondary.color)

                Text(SleepFormat.duration(state.now.timeIntervalSince(since)))
                    .font(.soft(88))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(palette.ink.color)

                Text(.locSinceTime(state.time(since)))
                    .font(.soft(17, weight: .bold))
                    .foregroundStyle(palette.inkSecondary.color)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(palette.accent.color)
                    .frame(width: 76, height: 76)
                    .glassEffect(.regular, in: .circle)
                Text("locNoSleepLoggedYet", comment: "Text in Timeline: No sleep logged yet")
                    .font(.soft(28))
                    .foregroundStyle(palette.ink.color)
                Text(.locEmptySleepDescription(childName))
                    .font(.soft(17, weight: .semibold))
                    .foregroundStyle(palette.inkSecondary.color)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
        }
    }

    private func panel(_ state: SleepHomeState) -> some View {
        GlassCard(cornerRadius: 36, padding: 18) {
            VStack(spacing: 14) {
                if state.since != nil {
                    HStack(spacing: 8) {
                        if let estimate = state.estimateText {
                            Image(systemName: state.active == nil ? "sparkles" : "sunrise.fill")
                                .foregroundStyle(palette.accent.color)
                            Text(estimate)
                                .foregroundStyle(palette.ink.color)
                        }
                        Spacer(minLength: 8)
                        Text(.locAsleepToday(SleepFormat.duration(state.asleepToday)))
                            .foregroundStyle(palette.inkSecondary.color)
                    }
                    .font(.soft(15, weight: .bold))
                    .padding(.horizontal, 4)
                }

                if state.since != nil {
                    DayStrip(state: state)
                        .padding(.horizontal, 4)
                }

                primaryButton(state)

                if !state.diary.days.isEmpty {
                    Label {
                        Text("locSwipeUpForDiary", comment: "Hint under the main sleep button that the diary is below")
                    } icon: {
                        Image(systemName: "chevron.up")
                    }
                    .font(.soft(12, weight: .bold))
                    .foregroundStyle(palette.inkSecondary.color)
                }
            }
        }
    }

    @ViewBuilder
    private func primaryButton(_ state: SleepHomeState) -> some View {
        if let active = state.active {
            Button { onWake(active.id) } label: {
                Label(.locChildWokeUp(childName), systemImage: "sun.max.fill")
                    .font(.soft(18))
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .foregroundStyle(palette.onWake.color)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(palette.wake.color)
            .disabled(isWaking)
            .accessibilityHint(LocalizedStringResource("locEndsTheCurrentSleepAtThePresentTime", defaultValue: "Ends the current sleep at the present time", comment: "Text in Timeline: Ends the current sleep at the present time"))
        } else {
            Button(action: onStart) {
                Label(LocalizedStringResource("locStartSleep", defaultValue: "Start sleep", comment: "Label in Timeline: Start sleep"), systemImage: "moon.fill")
                    .font(.soft(18))
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .foregroundStyle(palette.onAccent.color)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(palette.accent.color)
        }
    }
}

/// Everything the sleep tab derives from the projection at one moment.
struct SleepHomeState {
    let now: Date
    let calendar: Calendar
    let sessions: [SleepSession]
    let active: SleepSession?
    let latest: SleepSession?
    let activeKind: SleepKind?
    let prediction: SleepPrediction?
    let diary: SleepDiary
    let asleepToday: TimeInterval
    let timeStyle: Date.FormatStyle

    init(sessions: [SleepSession], forecast: SleepForecast?, now: Date, calendar: Calendar, timeStyle: Date.FormatStyle) {
        self.timeStyle = timeStyle
        self.now = now
        self.calendar = calendar
        self.sessions = sessions
        active = sessions.first { $0.endedAt == nil }
        latest = sessions.max { $0.startedAt < $1.startedAt }
        activeKind = active.map { SleepKind(startedAt: $0.startedAt, calendar: calendar) }
        prediction = active == nil ? forecast?.nextSleepEstimate : forecast?.wakeEstimate
        diary = SleepDiary(sessions: sessions, now: now, calendar: calendar)
        asleepToday = SleepTrends(sessions: sessions, rangeDays: 1, now: now, calendar: calendar).totalSeconds
    }

    var since: Date? { active?.startedAt ?? latest?.endedAt }

    /// Clock times follow the environment locale and time zone, not the process defaults.
    func time(_ date: Date) -> String { date.formatted(timeStyle) }

    var heroLabel: LocalizedStringResource {
        switch activeKind {
        case .night: LocalizedStringResource("locSleepingFor", defaultValue: "sleeping for", comment: "Label above the running timer while the baby sleeps at night")
        case .nap: LocalizedStringResource("locNappingFor", defaultValue: "napping for", comment: "Label above the running timer while the baby naps")
        case nil: LocalizedStringResource("locAwakeFor", defaultValue: "awake for", comment: "Label above the running timer while the baby is awake")
        }
    }

    var estimateText: LocalizedStringResource? {
        guard let prediction else { return nil }
        let time = time(prediction.targetAt)
        return active == nil ? .locNextSleepLikelyAround(time) : .locLikelyAwakeAround(time)
    }

    /// Day view by default; a night sleep shows the evening-to-morning window instead.
    var stripWindow: DateInterval {
        if activeKind == .night, let active {
            let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: active.startedAt) ?? active.startedAt
            let start = evening > active.startedAt ? calendar.date(byAdding: .day, value: -1, to: evening) ?? evening : evening
            return DateInterval(start: start, duration: 16 * 3_600)
        }
        let start = calendar.startOfDay(for: now)
        return DateInterval(start: start, duration: 24 * 3_600)
    }
}

/// One line of the day: night sleeps, naps, the likely next window, and now.
struct DayStrip: View {
    @Environment(\.palette) private var palette
    let state: SleepHomeState

    var body: some View {
        let window = state.stripWindow
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.track.color.opacity(palette.mode == .day ? 0.85 : 0.6))
                    ForEach(state.sessions.filter { overlaps($0, window) }) { session in
                        let range = clip(session.startedAt, session.endedAt ?? state.now, to: window)
                        Capsule()
                            .fill(SleepKind(startedAt: session.startedAt, calendar: state.calendar) == .night ? palette.accent.color : palette.accentSoft.color)
                            .frame(width: max(6, fraction(range.duration, window) * width))
                            .offset(x: fraction(range.start.timeIntervalSince(window.start), window) * width)
                    }
                    if let prediction = state.prediction {
                        let range = clip(prediction.rangeStartAt, prediction.rangeEndAt, to: window)
                        if range.duration > 0 {
                            Capsule()
                                .strokeBorder(palette.accent.color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                                .frame(width: max(8, fraction(range.duration, window) * width))
                                .offset(x: fraction(range.start.timeIntervalSince(window.start), window) * width)
                        }
                    }
                    if window.contains(state.now) {
                        Capsule()
                            .fill(palette.ink.color)
                            .frame(width: 3, height: 22)
                            .offset(x: fraction(state.now.timeIntervalSince(window.start), window) * width - 1.5)
                    }
                }
            }
            .frame(height: 14)

            HStack {
                ForEach(ticks(window), id: \.self) { tick in
                    Text(tick)
                    if tick != ticks(window).last { Spacer() }
                }
            }
            .font(.soft(11, weight: .bold))
            .foregroundStyle(palette.inkSecondary.color)
        }
        .accessibilityHidden(true)
    }

    private func overlaps(_ session: SleepSession, _ window: DateInterval) -> Bool {
        session.startedAt < window.end && (session.endedAt ?? state.now) > window.start
    }

    private func clip(_ start: Date, _ end: Date, to window: DateInterval) -> DateInterval {
        let lower = max(start, window.start)
        let upper = max(lower, min(end, window.end))
        return DateInterval(start: lower, end: upper)
    }

    private func fraction(_ seconds: TimeInterval, _ window: DateInterval) -> CGFloat {
        CGFloat(seconds / window.duration)
    }

    private func ticks(_ window: DateInterval) -> [String] {
        let steps = 4
        return (0...steps).map { step in
            let date = window.start.addingTimeInterval(window.duration * Double(step) / Double(steps))
            let hour = state.calendar.component(.hour, from: date)
            return String(format: "%02d", step == steps && hour == 0 ? 24 : hour)
        }
    }
}

/// The diary: sleeps grouped by the day they ended, newest first.
struct SleepDiaryList: View {
    @Environment(\.palette) private var palette
    let state: SleepHomeState
    let onSelectSession: (SleepSession) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(state.diary.days) { day in
                HStack(alignment: .firstTextBaseline) {
                    Text(dayTitle(day.date))
                        .font(.soft(17))
                        .foregroundStyle(palette.ink.color)
                    Spacer()
                    Text(summary(day))
                        .font(.soft(13, weight: .bold))
                        .foregroundStyle(palette.inkSecondary.color)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)

                GlassCard(cornerRadius: 26, padding: 0) {
                    VStack(spacing: 0) {
                        if state.calendar.isDate(day.date, inSameDayAs: state.now), state.active == nil, let prediction = state.prediction {
                            estimateRow(prediction)
                            Divider().padding(.leading, 34)
                        }
                        ForEach(day.entries) { entry in
                            row(entry)
                            if entry.id != day.entries.last?.id {
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func row(_ entry: SleepDiary.Entry) -> some View {
        Button { onSelectSession(entry.session) } label: {
            HStack(spacing: 12) {
                Capsule()
                    .fill(entry.kind == .night ? palette.accent.color : palette.accentSoft.color)
                    .frame(width: 6, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.isActive ? LocalizedStringResource("locSleepingNow", defaultValue: "Sleeping now", comment: "Label in Timeline: Sleeping now") : kindTitle(entry.kind))
                        .font(.soft(16, weight: .bold))
                        .foregroundStyle(palette.ink.color)
                    Text(range(entry))
                        .font(.soft(14, weight: .semibold))
                        .foregroundStyle(palette.inkSecondary.color)
                }
                Spacer()
                Text(SleepFormat.duration(entry.duration))
                    .font(.soft(16))
                    .monospacedDigit()
                    .foregroundStyle(palette.ink.color)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(palette.inkSecondary.color)
            }
            .padding(.vertical, 11)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(LocalizedStringResource("locOpensThisSleepForEditing", defaultValue: "Opens this sleep for editing", comment: "Message in Timeline: Opens this sleep for editing"))
    }

    private func estimateRow(_ prediction: SleepPrediction) -> some View {
        HStack(spacing: 12) {
            Capsule()
                .strokeBorder(palette.accent.color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: 6, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("locNextSleepEstimate", comment: "Diary row for the predicted next sleep; it is an estimate, not a record")
                    .font(.soft(16, weight: .bold))
                    .foregroundStyle(palette.ink.color)
                Text(.locLikelyRange(
                    state.time(prediction.rangeStartAt),
                    state.time(prediction.rangeEndAt)
                ))
                .font(.soft(14, weight: .semibold))
                .foregroundStyle(palette.inkSecondary.color)
            }
            Spacer()
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private func kindTitle(_ kind: SleepKind) -> LocalizedStringResource {
        switch kind {
        case .nap: LocalizedStringResource("locNapEntry", defaultValue: "Nap", comment: "Diary row title for a daytime sleep")
        case .night: LocalizedStringResource("locNightEntry", defaultValue: "Night", comment: "Diary row title for a night sleep")
        }
    }

    private func range(_ entry: SleepDiary.Entry) -> String {
        let start = state.time(entry.session.startedAt)
        let end = entry.session.endedAt.map(state.time)
            ?? String(localized: LocalizedStringResource("locNowLowercase", defaultValue: "now", comment: "Message in Timeline: now"))
        return String(localized: .locTimeRange(start, end))
    }

    private func dayTitle(_ date: Date) -> String {
        if state.calendar.isDate(date, inSameDayAs: state.now) {
            return String(localized: LocalizedStringResource("locToday", defaultValue: "Today", comment: "Message in Timeline: Today"))
        }
        if let yesterday = state.calendar.date(byAdding: .day, value: -1, to: state.now), state.calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: LocalizedStringResource("locYesterday", defaultValue: "Yesterday", comment: "Diary section title for the previous day"))
        }
        return date.formatted(Date.FormatStyle(locale: state.timeStyle.locale, calendar: state.calendar, timeZone: state.calendar.timeZone).weekday(.wide).day().month())
    }

    private func summary(_ day: SleepDiary.Day) -> String {
        let asleep = String(localized: .locDiaryAsleep(SleepFormat.duration(day.asleepSeconds)))
        guard day.napCount > 0 else { return asleep }
        return "\(asleep) · \(String(localized: .locDiaryNapCount(String(day.napCount))))"
    }
}

extension EnvironmentValues {
    /// Opens the sleep tab scrolled to the diary; used by previews and snapshots.
    @Entry var sleepHomeStartsAtDiary = false
}

enum SleepFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds))
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

struct SleepSectionTitle: View {
    @Environment(\.palette) private var palette
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.soft(18))
                .foregroundStyle(palette.ink.color)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.soft(13, weight: .bold))
                    .foregroundStyle(palette.inkSecondary.color)
            }
        }
    }
}
