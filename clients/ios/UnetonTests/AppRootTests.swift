import ComposableArchitecture2
import ComposableArchitectureTestSupport
import Foundation
import Testing
@testable import Uneton

@MainActor
struct AppRootTests {
    @Test func `selection follows authentication and family changes`() async {
        let firstFamily = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let secondFamily = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let store = TestStore(initialState: AppRoot.State(isAuthenticated: true)) {
            AppRoot()
        }

        store.send(.familySelected(firstFamily)) {
            $0.familySync = FamilySync.State.DebugSnapshot(familyID: firstFamily)
        }
        store.send(.familySelected(secondFamily)) {
            $0.familySync = FamilySync.State.DebugSnapshot(familyID: secondFamily)
        }
        store.send(.authenticationChanged(false)) {
            $0.isAuthenticated = false
            $0.familySync = nil
        }
        store.send(.familySelected(firstFamily))
        await store.dismount()
    }

    @Test func `foreground observation ends when the scene backgrounds`() async {
        let familyID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        var client = SessionSyncClient.unimplemented
        client.observe = { _ in
            try? await Task.sleep(for: .seconds(3600))
        }
        let store = TestStore(initialState: FamilySync.State(familyID: familyID)) {
            FamilySync()
                .environment(\.sessionSync, client)
        }

        store.send(.foregroundChanged(true)) {
            $0.isForeground = true
        }
        #expect(store.observation.isRunning)
        let backgroundTask = store.send(.foregroundChanged(false)) {
            $0.isForeground = false
        }
        await backgroundTask?.value
        #expect(!store.observation.isRunning)
        await store.dismount()
    }

    @Test func `invalid invitation leaves family setup recoverable`() async {
        let store = TestStore(initialState: FamilySetup.State()) {
            FamilySetup()
        }
        store.send(.scanInvitationButtonTapped) {
            $0.isScanning = true
        }
        store.send(.invitationCodeScanned("https://example.com/not-an-invite")) {
            $0.isScanning = false
            $0.errorMessage = "Invalid family invitation"
        }
        await store.dismount()
    }

    @Test func `invalid sleep interval never enters the command queue`() async {
        let familyID = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
        let childID = UUID(uuidString: "00000000-0000-4000-8000-000000000005")!
        var state = SleepEntry.State(familyID: familyID, childID: childID, childName: "Child")
        state.usesCustomStart = true
        state.hasEnd = true
        state.startedAt = Date(timeIntervalSince1970: 1_000)
        state.endedAt = Date(timeIntervalSince1970: 900)
        let store = TestStore(initialState: state) { SleepEntry() }

        #expect(store.validationError == "End time must be after start time.")
        store.send(.saveButtonTapped)
        #expect(!store.save.isRunning)
        await store.dismount()
    }

}
