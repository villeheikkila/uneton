import ComposableArchitecture2
import Foundation
import Observation
import SQLiteData
import UnetonCore

@Feature
struct FamilyManagement {
    enum Confirmation: Equatable {
        case remove(UserID)
        case transfer(UserID)
        case revoke(FamilyInviteID)
        case leave
        case deleteFamily
    }

    struct State {
        let familyID: Family.ID
        @ObservationIgnored @DebugSnapshotIgnored @FetchAll var children: [Child]
        var snapshot: FamilyManagementSnapshot?
        var profileName = ""
        var familyName = ""
        var errorMessage: String?
        var inviteURL: URL?
        var confirmation: Confirmation?
        var childEditor: ChildEditor.State?
        var sharing: FamilySharing.State?
        var newChildName = ""
        var newChildBirthDate = Calendar.current.date(byAdding: .month, value: -6, to: .now) ?? .now
        var newChildReference = "none"
        var isAddingChild = false
        var isScanning = false
        var isCreatingFamily = false
        var newFamilyName = ""
        var newFamilyID: Family.ID?
        var isFinished = false
        @StoreTaskID var load
        @StoreTaskID var request

        init(familyID: Family.ID) {
            self.familyID = familyID
            _children = FetchAll(Child.where { $0.familyID.eq(familyID) }
                .order { $0.updatedAt.desc() })
        }

        var isLoadingChildren: Bool { $children.isLoading }
    }

    enum Action {
        case refresh
        case saveProfile
        case saveFamilyName
        case invite
        case confirmationAccepted(Confirmation)
        case prompt(Confirmation)
        case dismissConfirmation
        case dismissAddChild
        case dismissCreateFamily
        case editChild(Child)
        case addChild
        case saveNewChild
        case scanInvitation
        case invitationCodeScanned(String)
        case createFamily
        case saveNewFamily
        case showDeviceSettings(Bool, Bool, Int)
        case childEditor(ChildEditor.Action)
        case sharing(FamilySharing.Action)
    }

    @FeatureEnvironment(\.sessionFamilyManagement) private var management
    @FeatureEnvironment(\.sessionFamily) private var sessionFamily
    @FeatureEnvironment(\.uuid) private var uuid

    var body: some Feature {
        Update { state, action in
            switch action {
            case .refresh:
                guard !state.request.isRunning else { return }
                let familyID = state.familyID
                store.addTask(id: state.load) {
                    do {
                        let snapshot = try await management.load(familyID)
                        try store.modify {
                            $0.snapshot = snapshot
                            $0.profileName = snapshot.myDisplayName
                            $0.familyName = snapshot.familyName
                            $0.errorMessage = nil
                        }
                    } catch {
                        try store.modify { $0.errorMessage = error.localizedDescription }
                    }
                }
            case .saveProfile:
                let name = state.profileName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { state.errorMessage = "Enter your name."; return }
                let familyID = state.familyID
                store.addTask(id: state.request) {
                    do {
                        try await management.updateProfile(name)
                        let snapshot = try await management.load(familyID)
                        try store.modify { $0.snapshot = snapshot; $0.errorMessage = nil }
                    } catch { try store.modify { $0.errorMessage = error.localizedDescription } }
                }
            case .saveFamilyName:
                let name = state.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { state.errorMessage = "Enter a family name."; return }
                let familyID = state.familyID
                store.addTask(id: state.request) {
                    do {
                        try await management.renameFamily(familyID, name)
                        let snapshot = try await management.load(familyID)
                        try store.modify { $0.snapshot = snapshot; $0.errorMessage = nil }
                    } catch { try store.modify { $0.errorMessage = error.localizedDescription } }
                }
            case .invite:
                let familyID = state.familyID
                store.addTask(id: state.request) {
                    do {
                        let url = try await management.invite(familyID)
                        let snapshot = try await management.load(familyID)
                        try store.modify { $0.inviteURL = url; $0.snapshot = snapshot; $0.errorMessage = nil }
                    } catch {
                        try store.modify { $0.errorMessage = error.localizedDescription }
                    }
                }
            case let .confirmationAccepted(confirmation):
                state.confirmation = nil
                let familyID = state.familyID
                store.addTask(id: state.request) {
                    do {
                        switch confirmation {
                        case let .remove(userID): try await management.removeMember(familyID, userID)
                        case let .transfer(userID): try await management.transferOwnership(familyID, userID)
                        case let .revoke(inviteID): try await management.revokeInvite(familyID, inviteID)
                        case .leave: try await management.leaveFamily(familyID)
                        case .deleteFamily: try await management.deleteFamily(familyID)
                        }
                        if confirmation == .leave || confirmation == .deleteFamily {
                            try store.modify { $0.isFinished = true }
                        } else {
                            let snapshot = try await management.load(familyID)
                            try store.modify { $0.snapshot = snapshot; $0.errorMessage = nil }
                        }
                    } catch {
                        try store.modify { $0.errorMessage = error.localizedDescription }
                    }
                }
            case let .prompt(confirmation):
                state.confirmation = confirmation
            case .dismissConfirmation:
                state.confirmation = nil
            case .dismissAddChild:
                state.isAddingChild = false
            case .dismissCreateFamily:
                state.isCreatingFamily = false
            case let .editChild(child):
                state.childEditor = ChildEditor.State(child: child)
            case .addChild:
                state.isAddingChild = true
            case .saveNewChild:
                let name = state.newChildName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { state.errorMessage = "Enter your baby’s name."; return }
                let familyID = state.familyID
                let birthDate = state.newChildBirthDate
                let reference = state.newChildReference
                store.addTask(id: state.request) {
                    do {
                        try await management.addChild(familyID, name, birthDate, reference)
                        try store.modify {
                            $0.isAddingChild = false
                            $0.newChildName = ""
                            $0.errorMessage = nil
                        }
                    } catch {
                        try store.modify { $0.errorMessage = error.localizedDescription }
                    }
                }
            case .scanInvitation:
                state.isScanning = true
            case let .invitationCodeScanned(code):
                state.isScanning = false
                guard let url = URL(string: code), url.scheme == "uneton", url.host == "invite",
                      url.pathComponents.dropFirst().first != nil else {
                    state.errorMessage = "Invalid family invitation."
                    return
                }
                store.addTask(id: state.request) {
                    let error = await sessionFamily.handleInvitation(url)
                    try store.modify { $0.errorMessage = error }
                }
            case .createFamily:
                state.isCreatingFamily = true
                state.newFamilyID = Family.ID(rawValue: uuid())
            case .saveNewFamily:
                let name = state.newFamilyName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let id = state.newFamilyID else {
                    state.errorMessage = "Enter a family name."
                    return
                }
                store.addTask(id: state.request) {
                    do {
                        try await management.createFamily(id, name)
                        try store.modify {
                            $0.isCreatingFamily = false
                            $0.newFamilyName = ""
                            $0.newFamilyID = nil
                            $0.errorMessage = nil
                        }
                    } catch { try store.modify { $0.errorMessage = error.localizedDescription } }
                }
            case let .showDeviceSettings(notifications, activities, leadMinutes):
                state.sharing = FamilySharing.State(notificationsEnabled: notifications, liveActivitiesEnabled: activities,
                    reminderLeadMinutes: leadMinutes)
            case .childEditor, .sharing:
                break
            }
        }
        .ifLet(\.childEditor) { ChildEditor() }
        .ifLet(\.sharing) { FamilySharing() }
    }

}

@Feature
struct ChildEditor {
    struct State {
        var child: Child
        var errorMessage: String?
        var isFinished = false
        var isConfirmingDeletion = false
        @StoreTaskID var request

        var validationMessage: String? {
            if child.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter your baby’s name."
            }
            if child.predictionMode == "manual" && (child.manualIntervalMinutes ?? 0) <= 0 {
                return "Choose a manual interval."
            }
            if TimeZone(identifier: child.timeZone) == nil {
                return "Enter a valid time zone, such as Europe/Helsinki."
            }
            return nil
        }
    }

    enum Action { case save, delete, promptDelete }
    @FeatureEnvironment(\.sessionFamilyManagement) private var management

    var body: some Feature {
        Update { state, action in
            switch action {
            case .save:
                if let error = state.validationMessage {
                    state.errorMessage = error
                    return
                }
                let child = state.child
                store.addTask(id: state.request) {
                    do {
                        try await management.updateChild(child)
                        try store.modify { $0.isFinished = true; $0.errorMessage = nil }
                    } catch { try store.modify { $0.errorMessage = error.localizedDescription } }
                }
            case .delete:
                let child = state.child
                store.addTask(id: state.request) {
                    do {
                        try await management.deleteChild(child)
                        try store.modify { $0.isFinished = true; $0.errorMessage = nil }
                    } catch { try store.modify { $0.errorMessage = error.localizedDescription } }
                }
            case .promptDelete:
                state.isConfirmingDeletion = true
            }
        }
    }
}
