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
        case growthTab
        case temperatureTab
        case insightsTab
        case sleepEntrySheet
        case growthEntrySheet
        case familySharingSheet
        case syncConflictsSheet

        var hasSheet: Bool {
            switch self {
            case .invitationScannerSheet, .sleepEntrySheet, .growthEntrySheet, .familySharingSheet, .syncConflictsSheet: true
            default: false
            }
        }
    }

    static let now = ModelFixtures.now
    private static let databasePrepared: Void = {
        try! prepareDependencies { try $0.bootstrapDatabase(inMemory: true) }
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
            try GrowthMeasurement.delete().execute(database)
            try SleepSession.delete().execute(database)
            try Child.delete().execute(database)
            try Family.delete().execute(database)
            try Family.insert { family }.execute(database)
            try Child.insert { child }.execute(database)
            try SleepSession.insert { sleep }.execute(database)
            try GrowthMeasurement.insert { growth }.execute(database)
            if scenario == .syncConflictsSheet {
                try SyncConflict.insert { conflict }.execute(database)
            }
        }
    }

    static func makeView(_ scenario: Scenario) -> AnyView {
        let session = SessionStore(demo: true)
        let demo = DemoRuntime(session: session)
        return AnyView(screen(scenario, demo: demo)
            .environment(session)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .environment(\.calendar, utcCalendar)
            .environment(\.unetonDisplayNow, now)
            .transaction { $0.disablesAnimations = true })
    }

    static func preview(_ scenario: Scenario) -> some View {
        prepareDatabase()
        return ScreenPreview(scenario: scenario)
    }

    private static var utcCalendar: Calendar {
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
            return AnyView(OnboardingView(store: store, prepareAppleAuthorization: { _ in }))
        case .familySetup, .invitationScannerSheet:
            var state = FamilySetup.State()
            state.birthDate = child.birthDate
            state.childName = child.nickname
            state.growthReference = "girl"
            state.isScanning = scenario == .invitationScannerSheet
            let store = Store(initialState: state) {
                FamilySetup().environment(\.sessionFamily, demo.family)
            }
            return AnyView(FamilySetupView(store: store))
        default:
            var state = FamilySync.State(familyID: family.id)
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
                    familyID: family.id, notificationsEnabled: true,
                    liveActivitiesEnabled: true, reminderLeadMinutes: 15
                )
            case .syncConflictsSheet:
                state.isPresentingConflicts = true
            default:
                break
            }
            var syncClient = SessionSyncClient.unimplemented
            syncClient.observe = { _ in }
            syncClient.refresh = { _ in }
            var sharingClient = demo.sharing
            sharingClient.createInvite = { _ in (URL(string: "uneton://invite/snapshot-code"), nil) }
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
            }
            return AnyView(TimelineScreen(syncStore: store, family: family, child: child))
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
