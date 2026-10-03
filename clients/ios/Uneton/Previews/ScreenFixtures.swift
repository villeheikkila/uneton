#if DEBUG
import ComposableArchitecture2
import Dependencies
import Foundation
import SQLiteData
import SwiftUI
import UnetonCore

/// The one visual fixture for Xcode previews and iPhone snapshot tests.
@MainActor
enum ScreenFixtures {
    enum Scenario: String, CaseIterable, Sendable {
        case onboarding
        case familySetup
        case invitationScannerSheet
        case sleepTab
        case sleepTabNapping
        case sleepTabNight
        case sleepTabNightLight
        case sleepDiary
        case growthTab
        case temperatureTab
        case insightsTab
        case sleepEntrySheet
        case growthEntrySheet
        case familySharingSheet
        case familyManagementSheet
        case childEditorSheet
        case syncConflictsSheet

        var isSleepTab: Bool {
            switch self {
            case .sleepTab, .sleepTabNapping, .sleepTabNight, .sleepTabNightLight, .sleepDiary: true
            default: false
            }
        }

        var hasSheet: Bool {
            switch self {
            case .invitationScannerSheet, .sleepEntrySheet, .growthEntrySheet, .familySharingSheet, .familyManagementSheet, .childEditorSheet, .syncConflictsSheet: true
            default: false
            }
        }
    }

    static let now = ModelFixtures.now

    /// Night scenarios look at the evening of the fixture day.
    static func now(for scenario: Scenario) -> Date {
        switch scenario {
        case .sleepTabNight, .sleepTabNightLight: utcCalendar.startOfDay(for: now).addingTimeInterval((21 * 60 + 40) * 60)
        default: now
        }
    }

    /// A week-like history so the sleep tab shows a real diary.
    private static func sleepHistory(_ scenario: Scenario) -> [SleepSession] {
        let day = utcCalendar.startOfDay(for: now)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            day.addingTimeInterval(Double(dayOffset * 86_400 + (hour * 60 + minute) * 60))
        }
        func sleep(_ index: Int, _ start: Date, _ end: Date?) -> SleepSession {
            ModelFixtures.sleep(
                id: SleepSession.ID(uuidString: String(format: "00000000-0000-4000-8000-%012d", 900 + index))!,
                startedAt: start, endedAt: end
            )
        }
        var history = [
            sleep(1, at(-2, 19, 20), at(-1, 6, 50)),
            sleep(2, at(-1, 8, 53), at(-1, 10, 12)),
            sleep(3, at(-1, 12, 43), at(-1, 14, 10)),
            sleep(4, at(-1, 16, 48), at(-1, 17, 24)),
            sleep(5, at(-1, 19, 30), at(0, 6, 40)),
            sleep(6, at(0, 8, 45), at(0, 10, 0)),
        ]
        switch scenario {
        case .sleepTabNapping:
            history.append(sleep(7, at(0, 13, 20), nil))
        case .sleepTabNight, .sleepTabNightLight:
            history.append(sleep(7, at(0, 11, 50), at(0, 13, 5)))
            history.append(sleep(8, at(0, 15, 40), at(0, 16, 20)))
            history.append(sleep(9, at(0, 19, 30), nil))
        default:
            history.append(sleep(7, at(0, 11, 50), at(0, 13, 5)))
        }
        return history
    }

    private static func forecast(_ scenario: Scenario) -> SleepForecast? {
        let reference = now(for: scenario)
        func prediction(_ target: Date) -> SleepPrediction {
            SleepPrediction(targetAt: target, rangeStartAt: target.addingTimeInterval(-15 * 60),
                rangeEndAt: target.addingTimeInterval(15 * 60), confidence: "medium", explanation: "", algorithmVersion: 1)
        }
        switch scenario {
        case .sleepTab, .sleepDiary:
            return SleepForecast(childID: ModelFixtures.childID, nextSleepEstimate: prediction(reference.addingTimeInterval(80 * 60)))
        case .sleepTabNapping:
            return SleepForecast(childID: ModelFixtures.childID, wakeEstimate: prediction(reference.addingTimeInterval(25 * 60)))
        case .sleepTabNight, .sleepTabNightLight:
            let morning = utcCalendar.startOfDay(for: reference).addingTimeInterval(86_400 + (6 * 60 + 15) * 60)
            return SleepForecast(childID: ModelFixtures.childID, wakeEstimate: prediction(morning))
        default:
            return nil
        }
    }
    private static let databasePrepared: Void = {
        try! prepareDependencies {
            try $0.bootstrapDatabase(inMemory: true)
            $0.date = .constant(now)
            $0.uuid = .incrementing
        }
    }()

    private static var family: Family { ModelFixtures.family() }
    private static var child: Child { ModelFixtures.child() }
    private static var sleep: SleepSession { ModelFixtures.sleep() }
    private static var growth: GrowthMeasurement { ModelFixtures.growth() }

    private struct ConflictTimes: Encodable {
        let startedAt: Date
        let endedAt: Date
    }

    static func prepareDatabase() {
        _ = databasePrepared
    }

    static func seed(_ scenario: Scenario) async throws {
        prepareDatabase()
        @Dependency(\.defaultDatabase) var database
        let family = Self.family
        let child = Self.child
        let sleep = Self.sleep
        let growth = Self.growth
        let history = sleepHistory(scenario)
        let localConflictJSON = try JSONEncoder.uneton.encode(ConflictTimes(
            startedAt: now.addingTimeInterval(-4 * 3_600),
            endedAt: now.addingTimeInterval(-2 * 3_600)
        ))
        let serverConflictJSON = try JSONEncoder.uneton.encode(ConflictTimes(
            startedAt: now.addingTimeInterval(-5 * 3_600),
            endedAt: now.addingTimeInterval(-3 * 3_600)
        ))
        let conflict = ModelFixtures.conflict(
            localPayloadJSON: localConflictJSON, serverPayloadJSON: serverConflictJSON
        )
        try await database.write { database in
            try SyncConflict.delete().execute(database)
            try PendingCommand.delete().execute(database)
            try GrowthMeasurement.delete().execute(database)
            try SleepSession.delete().execute(database)
            try Child.delete().execute(database)
            try Family.delete().execute(database)
            try Family.insert { family }.execute(database)
            try Child.insert { child }.execute(database)
            if scenario.isSleepTab {
                for session in history {
                    try SleepSession.insert { session }.execute(database)
                }
            } else {
                try SleepSession.insert { sleep }.execute(database)
            }
            try GrowthMeasurement.insert { growth }.execute(database)
            if scenario == .syncConflictsSheet {
                try SyncConflict.insert { conflict }.execute(database)
            }
        }
    }

    static func makeView(_ scenario: Scenario) -> AnyView {
        let session = SessionStore(demo: true)
        session.forecast = forecast(scenario)
        UserDefaults.standard.set(scenario == .sleepTabNightLight, forKey: "nightLightEnabled")
        let demo = DemoRuntime(session: session)
        return AnyView(screen(scenario, demo: demo)
            .environment(session)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .environment(\.calendar, utcCalendar)
            .environment(\.unetonDisplayNow, now(for: scenario))
            .environment(\.sleepHomeStartsAtDiary, scenario == .sleepDiary)
            .transaction { $0.disablesAnimations = true })
    }

    static func preview(_ scenario: Scenario) -> some View {
        prepareDatabase()
        return ScreenPreview(scenario: scenario)
    }

    nonisolated static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func screen(_ scenario: Scenario, demo: DemoRuntime) -> AnyView {
        let family = Self.family
        let child = Self.child
        let growth = Self.growth
        switch scenario {
        case .onboarding:
            let store = Store(initialState: Onboarding.State()) {
                Onboarding().environment(\.sessionAuth, demo.auth)
            }
            return AnyView(OnboardingScreen(store: store, prepareAppleAuthorization: { _ in }))
        case .familySetup, .invitationScannerSheet:
            var state = FamilySetup.State()
            state.birthDate = child.birthDate
            state.childName = child.nickname
            state.growthReference = "girl"
            state.isScanning = scenario == .invitationScannerSheet
            let store = Store(initialState: state) {
                FamilySetup().environment(\.sessionFamily, demo.family)
            }
            return AnyView(FamilySetupScreen(store: store))
        default:
            var state = FamilySync.State(familyID: family.id, childID: child.id)
            switch scenario {
            case .sleepEntrySheet:
                state.entry = SleepEntry.State(familyID: family.id, childID: child.id, childName: child.nickname, now: now)
            case .growthEntrySheet:
                state.growthEntry = GrowthEntry.State(
                    familyID: family.id, childID: child.id,
                    measurementID: growth.id, measuredAt: growth.measuredAt,
                    weightGrams: growth.weightGrams, heightMillimeters: growth.heightMillimeters,
                    note: growth.note, now: now
                )
            case .familySharingSheet:
                state.sharing = FamilySharing.State(
                    notificationsEnabled: true,
                    liveActivitiesEnabled: true, reminderLeadMinutes: 15
                )
            case .familyManagementSheet, .childEditorSheet:
                state.management = FamilyManagement.State(familyID: family.id)
                state.management?.snapshot = FamilyManagementSnapshot(
                    familyID: family.id, familyName: family.name,
                    myUserID: ModelFixtures.authorID, myDisplayName: "Alex", myRole: "owner",
                    members: [
                        ManagedFamilyMember(id: ModelFixtures.authorID, displayName: "Alex", role: "owner",
                            joinedAt: now.addingTimeInterval(-90 * 86_400)),
                        ManagedFamilyMember(id: UserID(uuidString: "00000000-0000-4000-8000-000000000108")!,
                            displayName: "Sam", role: "caregiver", joinedAt: now.addingTimeInterval(-30 * 86_400))
                    ], pendingInvites: [])
                state.management?.profileName = "Alex"
                state.management?.familyName = family.name
                if scenario == .childEditorSheet {
                    state.management?.childEditor = ChildEditor.State(child: child)
                }
            case .syncConflictsSheet:
                state.isPresentingConflicts = true
            default:
                break
            }
            var syncClient = SessionSyncClient.unimplemented
            syncClient.observe = { _ in }
            syncClient.refresh = { _ in }
            let sharingClient = demo.sharing
            state.selectedTab = switch scenario {
            case .growthTab, .growthEntrySheet: .growth
            case .temperatureTab: .temperature
            case .insightsTab: .trends
            default: .timeline
            }
            let store = Store(initialState: state) {
                FamilySync()
                    .environment(\.sessionSync, syncClient)
                    .environment(\.sessionSharing, sharingClient)
                    .environment(\.sessionDiary, demo.diary)
                    .environment(\.sessionFamilyManagement, demo.management)
                    .environment(\.sessionFamily, demo.family)
            }
            return AnyView(TimelineScreen(syncStore: store, family: family, child: child,
                families: [family], children: [child]))
        }
    }
}

@MainActor
private struct ScreenPreview: View {
    let scenario: ScreenFixtures.Scenario
    @State private var renderedView: AnyView?
    @State private var error: String?

    var body: some View {
        Group {
            if let renderedView {
                renderedView
            } else if let error {
                ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                try await ScreenFixtures.seed(scenario)
                renderedView = ScreenFixtures.makeView(scenario)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

#endif
