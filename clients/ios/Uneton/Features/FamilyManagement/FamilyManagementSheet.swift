import ComposableArchitecture2
import SwiftUI

struct FamilyManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: StoreOf<FamilyManagement>

    var body: some View {
        NavigationStack {
            FamilyManagementContent(store: store)
                .refreshable { await store.send(.refresh)?.value }
                .navigationTitle(String(localized: LocalizedStringResource("locFamily", defaultValue: "Family", comment: "Screen title in FamilyManagement: Family")))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(String(localized: LocalizedStringResource("locDone", defaultValue: "Done", comment: "Button title in FamilyManagement: Done"))) { dismiss() } } }
            .sheet(item: $store.scope(\.childEditor)) { editor in
                ChildEditorSheet(store: editor)
            }
            .sheet(item: $store.scope(\.sharing)) { sharing in
                FamilySharingSheet(store: sharing)
            }
            .sheet(isPresented: $store.isAddingChild) {
                AddChildSheet(store: store)
            }
            .sheet(isPresented: $store.isCreatingFamily) {
                NewFamilySheet(store: store)
            }
            .sheet(isPresented: $store.isScanning) {
                InvitationScannerSheet { store.send(.invitationCodeScanned($0)) }
            }
            .confirmationDialog(String(localized: LocalizedStringResource("locConfirmFamilyChange", defaultValue: "Confirm family change", comment: "Message in FamilyManagement: Confirm family change")), isPresented: Binding(
                get: { store.confirmation != nil },
                set: { if !$0 { store.send(.dismissConfirmation) } }
            ), titleVisibility: .visible) {
                if let confirmation = store.confirmation {
                    Button(confirmation.title, role: confirmation.isDestructive ? .destructive : nil) {
                        store.send(.confirmationAccepted(confirmation))
                    }
                }
                Button(String(localized: LocalizedStringResource("locCancel", defaultValue: "Cancel", comment: "Button title in FamilyManagement: Cancel")), role: .cancel) { store.send(.dismissConfirmation) }
            } message: {
                Text(store.confirmation?.detail ?? "")
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await store.send(.refresh)?.value }
        }
        .onChange(of: store.isFinished) { _, finished in if finished { dismiss() } }
    }
}

private extension FamilyManagement.Confirmation {
    var title: String {
        switch self {
        case .remove: String(localized: LocalizedStringResource("locRemoveCaregiver", defaultValue: "Remove caregiver", comment: "Message in FamilyManagement: Remove caregiver"))
        case .transfer: String(localized: LocalizedStringResource("locTransferOwnership", defaultValue: "Transfer ownership", comment: "Message in FamilyManagement: Transfer ownership"))
        case .revoke: String(localized: LocalizedStringResource("locRevokeInvitation", defaultValue: "Revoke invitation", comment: "Message in FamilyManagement: Revoke invitation"))
        case .leave: String(localized: LocalizedStringResource("locLeaveFamily", defaultValue: "Leave family", comment: "Message in FamilyManagement: Leave family"))
        case .deleteFamily: String(localized: LocalizedStringResource("locDeleteFamily", defaultValue: "Delete family", comment: "Message in FamilyManagement: Delete family"))
        }
    }
    var detail: String {
        switch self {
        case .remove: String(localized: LocalizedStringResource("locThisCaregiverWillLoseAccessToTheFamily", defaultValue: "This caregiver will lose access to the family.", comment: "Message in FamilyManagement: This caregiver will lose access to the family."))
        case .transfer: String(localized: LocalizedStringResource("locTheSelectedCaregiverWillBecomeTheOwnerYouWillRemainACaregiver", defaultValue: "The selected caregiver will become the owner. You will remain a caregiver.", comment: "Message in FamilyManagement: The selected caregiver will become the owner. You will remain a caregiver."))
        case .revoke: String(localized: LocalizedStringResource("locTheInvitationWillStopWorking", defaultValue: "The invitation will stop working.", comment: "Message in FamilyManagement: The invitation will stop working."))
        case .leave: String(localized: LocalizedStringResource("locYouWillLoseAccessToThisFamilyAndItsBabyRecords", defaultValue: "You will lose access to this family and its baby records.", comment: "Message in FamilyManagement: You will lose access to this family and its baby records."))
        case .deleteFamily: String(localized: LocalizedStringResource("locThisPermanentlyDeletesTheFamilyAndItsBabyRecordsRemoveOtherCaregiversFirst", defaultValue: "This permanently deletes the family and its baby records. Remove other caregivers first.", comment: "Message in FamilyManagement: This permanently deletes the family and its baby records. Remove other caregivers first."))
        }
    }
    var isDestructive: Bool {
        switch self {
        case .transfer: false
        default: true
        }
    }
}


#if DEBUG
#Preview("Family management") { ScreenFixtures.preview(.familyManagementSheet) }
#endif
