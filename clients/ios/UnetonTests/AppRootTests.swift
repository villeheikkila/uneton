import ComposableArchitecture2
import ComposableArchitectureTestSupport
import DependenciesTestSupport
import Foundation
import Testing
import UnetonCore
@testable import Uneton

@MainActor
@Suite(.dependencies {
    try $0.bootstrapDatabase(inMemory: true)
})
struct AppRootTests {
    @Test func `baby settings save through the injected family client`() async {
        let child = ModelFixtures.child()
        var management = SessionFamilyManagementClient.unimplemented
        management.updateChild = { received in
            #expect(received == child)
        }
        let store = TestStore(initialState: ChildEditor.State(child: child)) {
            ChildEditor().environment(\.sessionFamilyManagement, management)
        }
        let task = store.send(.save) { $0.isFinished = true }
        await task?.value
        await store.dismount()
    }

    @Test func `manual prediction requires an interval before saving`() async {
        var child = ModelFixtures.child()
        child.predictionMode = "manual"
        let store = TestStore(initialState: ChildEditor.State(child: child)) { ChildEditor() }
        #expect(store.validationMessage == "Choose a manual interval.")
        store.send(.save) { $0.errorMessage = "Choose a manual interval." }
        #expect(!store.request.isRunning)
        await store.dismount()
    }

    @Test func `family management keeps an empty baby form recoverable`() async {
        let familyID = ModelFixtures.familyID
        var management = SessionFamilyManagementClient.unimplemented
        management.load = { id in
            FamilyManagementSnapshot(familyID: id, familyName: "Home",
                myUserID: ModelFixtures.authorID, myDisplayName: "Alex",
                myRole: "owner", members: [], pendingInvites: [])
        }
        let store = TestStore(initialState: FamilyManagement.State(familyID: familyID)) {
            FamilyManagement().environment(\.sessionFamilyManagement, management)
        }
        store.send(.addChild) { $0.isAddingChild = true }
        store.send(.saveNewChild) { $0.errorMessage = "Enter your baby’s name." }
        store.send(.scanInvitation) { $0.isScanning = true }
        store.send(.invitationCodeScanned("https://example.com")) {
            $0.isScanning = false
            $0.errorMessage = "Invalid family invitation."
        }
        await store.dismount()
    }

    @Test func `owner removal is confirmed and routed through the management client`() async {
        let familyID = ModelFixtures.familyID
        let caregiverID = UserID(uuidString: "00000000-0000-4000-8000-000000000120")!
        let snapshot = FamilyManagementSnapshot(familyID: familyID, familyName: "Home",
            myUserID: ModelFixtures.authorID, myDisplayName: "Alex",
            myRole: "owner", members: [], pendingInvites: [])
        var client = SessionFamilyManagementClient.unimplemented
        client.removeMember = { id, userID in
            #expect(id == familyID)
            #expect(userID == caregiverID)
        }
        client.load = { _ in snapshot }
        var state = FamilyManagement.State(familyID: familyID)
        state.snapshot = snapshot
        let store = TestStore(initialState: state) {
            FamilyManagement().environment(\.sessionFamilyManagement, client)
        }
        store.send(.prompt(.remove(caregiverID))) { $0.confirmation = .remove(caregiverID) }
        let task = store.send(.confirmationAccepted(.remove(caregiverID))) { $0.confirmation = nil }
        await task?.value
        await store.dismount()
    }

    @Test func `selection follows authentication and family changes`() async {
        let firstFamily = Family.ID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let secondFamily = Family.ID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let firstChild = Child.ID(uuidString: "00000000-0000-4000-8000-000000000010")!
        let store = TestStore(initialState: AppRoot.State(isAuthenticated: true)) {
            AppRoot()
        }

        store.send(.familySelected(firstFamily)) {
            $0.familyHome = FamilyHome.State.DebugSnapshot(familyID: firstFamily)
            $0.selectedFamilyID = firstFamily
        }
        store.send(.selectChild(firstChild)) {
            $0.selectedChildID = firstChild
            $0.familySync = FamilySync.State.DebugSnapshot(familyID: firstFamily, childID: firstChild)
        }
        store.send(.familySelected(secondFamily)) {
            $0.familyHome = FamilyHome.State.DebugSnapshot(familyID: secondFamily)
            $0.familySync = nil
            $0.selectedFamilyID = secondFamily
            $0.selectedChildID = nil
        }
        store.send(.authenticationChanged(false)) {
            $0.isAuthenticated = false
            $0.familyHome = nil
            $0.familySync = nil
            $0.selectedFamilyID = nil
        }
        store.send(.familySelected(firstFamily))
        await store.dismount()
    }

    @Test func `foreground observation ends when the scene backgrounds`() async {
        let familyID = Family.ID(uuidString: "00000000-0000-4000-8000-000000000003")!
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
        let familyID = Family.ID(uuidString: "00000000-0000-4000-8000-000000000004")!
        let childID = Child.ID(uuidString: "00000000-0000-4000-8000-000000000005")!
        var state = SleepEntry.State(familyID: familyID, childID: childID, childName: "Child", now: Date(timeIntervalSince1970: 2_000))
        state.usesCustomStart = true
        state.hasEnd = true
        state.startedAt = Date(timeIntervalSince1970: 1_000)
        state.endedAt = Date(timeIntervalSince1970: 900)
        let store = TestStore(initialState: state) { SleepEntry() }

        #expect(store.validationError == "End time must be after start time.")
        store.send(.saveButtonTapped) {
            $0.errorMessage = "End time must be after start time."
        }
        #expect(!store.save.isRunning)
        await store.dismount()
    }

    @Test func `starting now uses the injected time at submission`() async {
        let openedAt = Date(timeIntervalSince1970: 1_000)
        let submittedAt = Date(timeIntervalSince1970: 1_060)
        let familyID = Family.ID(uuidString: "00000000-0000-4000-8000-000000000006")!
        let childID = Child.ID(uuidString: "00000000-0000-4000-8000-000000000007")!
        var diary = SessionDiaryClient.unimplemented
        diary.startSleep = { _, _, _, startedAt in
            #expect(startedAt == submittedAt)
            return nil
        }
        let store = TestStore(initialState: SleepEntry.State(
            familyID: familyID, childID: childID, childName: "Child", now: openedAt
        )) {
            SleepEntry()
                .environment(\.sessionDiary, diary)
                .environment(\.date, .constant(submittedAt))
        }

        let task = store.send(.saveButtonTapped) {
            $0.isSaved = true
        }
        await task?.value
        await store.dismount()
    }

}
