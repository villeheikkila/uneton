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
                        try store.modify { $0.errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated")) }
                    }
                }
            case .saveProfile:
                let name = state.profileName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { state.errorMessage = String(localized: LocalizedStringResource("locEnterYourName", defaultValue: "Enter your name.", comment: "Message in FamilyManagement: Enter your name.")); return }
                let familyID = state.familyID
                store.addTask(id: state.request) {
                    do {
                        try await management.updateProfile(name)
                        let snapshot = try await management.load(familyID)
                        try store.modify { $0.snapshot = snapshot; $0.errorMessage = nil }
                    } catch { try store.modify { $0.errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated")) } }
                }
            case .saveFamilyName:
                let name = state.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { state.errorMessage = String(localized: LocalizedStringResource("locEnterAFamilyName", defaultValue: "Enter a family name.", comment: "Message in FamilyManagement: Enter a family name.")); return }
                let familyID = state.familyID
                store.addTask(id: state.request) {
                    do {
                        try await management.renameFamily(familyID, name)
                        let snapshot = try await management.load(familyID)
                        try store.modify { $0.snapshot = snapshot; $0.errorMessage = nil }
                    } catch { try store.modify { $0.errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated")) } }
                }
            case .invite:
                let familyID = state.familyID
                store.addTask(id: state.request) {
                    do {
                        let url = try await management.invite(familyID)
                        let snapshot = try await management.load(familyID)
                        try store.modify { $0.inviteURL = url; $0.snapshot = snapshot; $0.errorMessage = nil }
                    } catch {
                        try store.modify { $0.errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated")) }
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
                        try store.modify { $0.errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated")) }
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
                guard !name.isEmpty else { state.errorMessage = String(localized: LocalizedStringResource("locEnterYourBabySName", defaultValue: "Enter your baby’s name.", comment: "Message in FamilyManagement: Enter your baby’s name.")); return }
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
                        try store.modify { $0.errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated")) }
                    }
                }
            case .scanInvitation:
                state.isScanning = true
            case let .invitationCodeScanned(code):
                state.isScanning = false
                guard let url = URL(string: code), FamilyInvitationLink.token(from: url) != nil else {
                    state.errorMessage = String(localized: LocalizedStringResource("locInvalidFamilyInvitationPeriod", defaultValue: "Invalid family invitation.", comment: "Message in FamilyManagement: Invalid family invitation."))
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
                    state.errorMessage = String(localized: LocalizedStringResource("locEnterAFamilyName", defaultValue: "Enter a family name.", comment: "Message in FamilyManagement: Enter a family name."))
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
                    } catch { try store.modify { $0.errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated")) } }
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
        var isPickingImport = false
        var importPreview: HuckleberryImport?
        var importMessage: String?
        var errorMessage: String?
        var isFinished = false
        var isConfirmingDeletion = false
        @StoreTaskID var request

        var validationMessage: String? {
            if child.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(localized: LocalizedStringResource("locEnterYourBabySName", defaultValue: "Enter your baby’s name.", comment: "Message in FamilyManagement: Enter your baby’s name."))
            }
            if child.predictionMode == "manual" && (child.manualIntervalMinutes ?? 0) <= 0 {
                return String(localized: LocalizedStringResource("locChooseAManualInterval", defaultValue: "Choose a manual interval.", comment: "Message in FamilyManagement: Choose a manual interval."))
            }
            if TimeZone(identifier: child.timeZone) == nil {
                return String(localized: LocalizedStringResource("locEnterAValidTimeZoneSuchAsEuropeHelsinki", defaultValue: "Enter a valid time zone, such as Europe/Helsinki.", comment: "Message in FamilyManagement: Enter a valid time zone, such as Europe/Helsinki."))
            }
            return nil
        }
    }

    enum Action {
        case save, delete, promptDelete, chooseImport, confirmImport
        case importFileSelected(Result<URL, any Error>)
    }
    @FeatureEnvironment(\.sessionFamilyManagement) private var management

    var body: some Feature {
        Update { state, action in
            guard !state.request.isRunning else { return }
            switch action {
            case .chooseImport:
                state.importPreview = nil
                state.importMessage = nil
                state.errorMessage = nil
                state.isPickingImport = true
            case let .importFileSelected(result):
                state.isPickingImport = false
                guard case let .success(url) = result else {
                    if case let .failure(error) = result, (error as NSError).code != NSUserCancelledError {
                        state.errorMessage = String(localized: LocalizedStringResource("locImportReadError", defaultValue: "Could not read this file. Choose a Huckleberry CSV export.", comment: "File selection or CSV validation failed"))
                    }
                    return
                }
                guard let zone = TimeZone(identifier: state.child.timeZone) else { return }
                store.addTask(id: state.request) {
                    do {
                        let history = try await Task.detached {
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            let handle = try FileHandle(forReadingFrom: url)
                            defer { try? handle.close() }
                            let data = try handle.read(upToCount: HuckleberryImport.maximumBytes + 1) ?? Data()
                            return try HuckleberryImport.parse(data: data, timeZone: zone)
                        }.value
                        try store.modify {
                            if history.sleeps.isEmpty {
                                $0.errorMessage = String(localized: LocalizedStringResource("locImportNoSleep", defaultValue: "This export contains no completed sleep records.", comment: "The selected CSV has no sleep records to import"))
                            } else { $0.importPreview = history }
                        }
                    } catch {
                        try store.modify { $0.errorMessage = String(localized: LocalizedStringResource("locImportReadError", defaultValue: "Could not read this file. Choose a Huckleberry CSV export.", comment: "File selection or CSV validation failed")) }
                    }
                }
            case .confirmImport:
                guard let history = state.importPreview else { return }
                let child = state.child
                store.addTask(id: state.request) {
                    do {
                        let count = try await management.importHuckleberry(child, history)
                        try store.modify {
                            $0.importPreview = nil
                            $0.errorMessage = nil
                            $0.importMessage = String(localized: .locImportQueued(String(count)))
                        }
                    } catch { try store.modify { $0.errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated")) } }
                }
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
                    } catch { try store.modify { $0.errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated")) } }
                }
            case .delete:
                let child = state.child
                store.addTask(id: state.request) {
                    do {
                        try await management.deleteChild(child)
                        try store.modify { $0.isFinished = true; $0.errorMessage = nil }
                    } catch { try store.modify { $0.errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated")) } }
                }
            case .promptDelete:
                state.isConfirmingDeletion = true
            }
        }
        .onChange(of: store.child.timeZone) { state in
            state.importPreview = nil
        }
    }
}
