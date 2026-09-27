import ComposableArchitecture2
import Dependencies
import Foundation
import SnapshotTesting
import SQLiteData
import SwiftUI
import Testing
import UIKit
import UnetonCore
@testable import Uneton

/// References: Xcode 27.0 RC, iOS 26.5, iPhone 17 Pro, 402×874 points, 3×, arm64.
/// Use `mise run ios:snapshots:record` to deliberately replace references.
@Suite("Screen snapshots", .serialized)
@MainActor
struct ScreenSnapshots {
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

    private static let size = CGSize(width: 402, height: 874)
    private static let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)
    private static let familyID = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
    private static let childID = UUID(uuidString: "00000000-0000-4000-8000-000000000102")!
    private static let sleepID = UUID(uuidString: "00000000-0000-4000-8000-000000000103")!
    private static let growthID = UUID(uuidString: "00000000-0000-4000-8000-000000000104")!
    private static let databasePrepared: Void = {
        try! prepareDependencies { try $0.bootstrapDatabase() }
    }()

    private struct ConflictTimes: Encodable {
        let startedAt: Date
        let endedAt: Date
    }

    @Test(arguments: Scenario.allCases)
    func screen(_ scenario: Scenario) async throws {
        _ = Self.databasePrepared
        try await capture(scenario)
    }

    private func capture(_ scenario: Scenario) async throws {
        @Dependency(\.defaultDatabase) var database
        let family = Family(id: Self.familyID, name: "Our family", role: "owner", updatedAt: Self.fixedNow)
        let child = Child(
            id: Self.childID, familyID: Self.familyID, nickname: "Aino",
            birthDate: Self.fixedNow.addingTimeInterval(-180 * 86_400),
            revision: 1, updatedAt: Self.fixedNow
        )
        let sleep = SleepSession(
            id: Self.sleepID, familyID: Self.familyID, childID: Self.childID,
            startedAt: Self.fixedNow.addingTimeInterval(-3_600 * 4),
            endedAt: Self.fixedNow.addingTimeInterval(-3_600 * 2),
            revision: 1, authorID: UUID(uuidString: "00000000-0000-4000-8000-000000000105"),
            updatedAt: Self.fixedNow
        )
        let growth = GrowthMeasurement(
            id: Self.growthID, familyID: Self.familyID, childID: Self.childID,
            measuredAt: Self.fixedNow.addingTimeInterval(-86_400),
            weightGrams: 6_800, heightMillimeters: 660, note: "Neuvola",
            revision: 1, updatedAt: Self.fixedNow
        )
        let familyID = Self.familyID
        let sleepID = Self.sleepID
        let fixedNow = Self.fixedNow
        let localConflictJSON = try JSONEncoder.uneton.encode(ConflictTimes(
            startedAt: fixedNow.addingTimeInterval(-4 * 3_600),
            endedAt: fixedNow.addingTimeInterval(-2 * 3_600)
        ))
        let serverConflictJSON = try JSONEncoder.uneton.encode(ConflictTimes(
            startedAt: fixedNow.addingTimeInterval(-5 * 3_600),
            endedAt: fixedNow.addingTimeInterval(-3 * 3_600)
        ))
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
                let conflict = SyncConflict(
                    id: UUID(uuidString: "00000000-0000-4000-8000-000000000106")!,
                    familyID: familyID, entityType: "sleepSession", entityID: sleepID,
                    commandKind: "upsertSleep", expectedRevision: 1,
                    localPayloadJSON: localConflictJSON, serverPayloadJSON: serverConflictJSON,
                    reason: "stale revision",
                    createdAt: fixedNow
                )
                try SyncConflict.insert { conflict }.execute(database)
            }
        }
        if scenario == .syncConflictsSheet {
            #expect(try await database.read { try SyncConflict.fetchCount($0) } == 1)
        }

        let session = SessionStore()
        let root = AnyView(makeView(scenario, family: family, child: child, growth: growth)
            .environment(session)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .environment(\.calendar, utcCalendar)
            .environment(\.unetonDisplayNow, Self.fixedNow)
            .transaction { $0.disablesAnimations = true })
        let controller = UIHostingController(rootView: root)
        controller.overrideUserInterfaceStyle = .light
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.rootView = AnyView(EmptyView())
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        if scenario.hasSheet {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while controller.presentedViewController == nil && ContinuousClock.now < deadline {
                await Task.yield()
            }
            let presented = try #require(controller.presentedViewController, "Native sheet was not presented")
            #expect(presented.presentationController != nil)
        }
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(16))
            window.layoutIfNeeded()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: Self.size, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let strategy = Snapshotting<UIImage, UIImage>.image(
            precision: 0.98, perceptualPrecision: 0.90
        )
        #if UNETON_RECORD_SNAPSHOTS
            withKnownIssue("Explicit snapshot recording writes a reference") {
                assertSnapshot(of: image, as: strategy, named: scenario.rawValue, record: .all)
            }
        #else
            assertSnapshot(of: image, as: strategy, named: scenario.rawValue, record: .never)
        #endif
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeView(
        _ scenario: Scenario,
        family: Family,
        child: Child,
        growth: GrowthMeasurement
    ) -> AnyView {
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
