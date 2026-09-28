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

    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let familyID = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
    private static let childID = UUID(uuidString: "00000000-0000-4000-8000-000000000102")!
    private static let sleepID = UUID(uuidString: "00000000-0000-4000-8000-000000000103")!
    private static let growthID = UUID(uuidString: "00000000-0000-4000-8000-000000000104")!
    private static let databasePrepared: Void = {
        try! prepareDependencies { try $0.bootstrapDatabase() }
    }()

    private static var family: Family {
        Family(id: familyID, name: "Our family", role: "owner", updatedAt: now)
    }

    private static var child: Child {
        Child(
            id: childID, familyID: familyID, nickname: "Aino",
            birthDate: now.addingTimeInterval(-180 * 86_400),
            revision: 1, updatedAt: now
        )
    }

    private static var sleep: SleepSession {
        SleepSession(
            id: sleepID, familyID: familyID, childID: childID,
            startedAt: now.addingTimeInterval(-3_600 * 4),
            endedAt: now.addingTimeInterval(-3_600 * 2),
            revision: 1, authorID: UUID(uuidString: "00000000-0000-4000-8000-000000000105"),
            updatedAt: now
        )
    }

    private static var growth: GrowthMeasurement {
        GrowthMeasurement(
            id: growthID, familyID: familyID, childID: childID,
            measuredAt: now.addingTimeInterval(-86_400),
            weightGrams: 6_800, heightMillimeters: 660, note: "Neuvola",
            revision: 1, updatedAt: now
        )
    }

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
        let conflict = SyncConflict(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000106")!,
            familyID: familyID, entityType: "sleepSession", entityID: sleepID,
            commandKind: "upsertSleep", expectedRevision: 1,
            localPayloadJSON: localConflictJSON, serverPayloadJSON: serverConflictJSON,
            reason: "stale revision", createdAt: now
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
        let session = SessionStore()
        return AnyView(screen(scenario)
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

    private static func screen(_ scenario: Scenario) -> AnyView {
        let family = Self.family
        let child = Self.child
        let growth = Self.growth
        switch scenario {
        case .onboarding:
            let store = Store(initialState: Onboarding.State()) { Onboarding() }
            return AnyView(OnboardingView(store: store, prepareAppleAuthorization: { _ in }))
        case .familySetup, .invitationScannerSheet:
            var state = FamilySetup.State()
            state.birthDate = child.birthDate
            state.childName = child.nickname
            state.growthReference = "girl"
            state.isScanning = scenario == .invitationScannerSheet
            let store = Store(initialState: state) { FamilySetup() }
            return AnyView(FamilySetupView(store: store))
        default:
            var state = FamilySync.State(familyID: family.id)
            switch scenario {
            case .sleepEntrySheet:
                state.entry = SleepEntry.State(familyID: family.id, childID: child.id, childName: child.nickname)
            case .growthEntrySheet:
                state.growthEntry = GrowthEntry.State(
                    familyID: family.id, childID: child.id,
                    measurementID: growth.id, measuredAt: growth.measuredAt,
                    weightGrams: growth.weightGrams, heightMillimeters: growth.heightMillimeters,
                    note: growth.note
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
            var sharingClient = SessionSharingClient.unimplemented
            sharingClient.createInvite = { _ in (URL(string: "uneton://invite/snapshot-code"), nil) }
            let store = Store(initialState: state) {
                FamilySync()
                    .environment(\.sessionSync, syncClient)
                    .environment(\.sessionSharing, sharingClient)
            }
            let mode: TimelineScreen.Mode = switch scenario {
            case .growthTab, .growthEntrySheet: .growth
            case .insightsTab: .trends
            default: .timeline
            }
            return AnyView(TimelineScreen(
                syncStore: store, family: family, child: child, initialMode: mode
            ))
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
