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
                .navigationTitle("Family")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
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
            .confirmationDialog("Confirm family change", isPresented: Binding(
                get: { store.confirmation != nil },
                set: { if !$0 { store.send(.dismissConfirmation) } }
            ), titleVisibility: .visible) {
                if let confirmation = store.confirmation {
                    Button(confirmation.title, role: confirmation.isDestructive ? .destructive : nil) {
                        store.send(.confirmationAccepted(confirmation))
                    }
                }
                Button("Cancel", role: .cancel) { store.send(.dismissConfirmation) }
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
        case .remove: "Remove caregiver"
        case .transfer: "Transfer ownership"
        case .revoke: "Revoke invitation"
        case .leave: "Leave family"
        case .deleteFamily: "Delete family"
        }
    }
    var detail: String {
        switch self {
        case .remove: "This caregiver will lose access to the family."
        case .transfer: "The selected caregiver will become the owner. You will remain a caregiver."
        case .revoke: "The invitation will stop working."
        case .leave: "You will lose access to this family and its baby records."
        case .deleteFamily: "This permanently deletes the family and its baby records. Remove other caregivers first."
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
