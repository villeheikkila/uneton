import ComposableArchitecture2
import SwiftUI

struct FamilySharingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: StoreOf<FamilySharing>

    var body: some View {
        NavigationStack {
            FamilySharingContent(store: store)
                .navigationTitle(LocalizedStringResource("locSettings", defaultValue: "Settings", comment: "Screen title in Settings: Settings"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button(LocalizedStringResource("locDone", defaultValue: "Done", comment: "Button title in Settings: Done")) { dismiss() } }
            .confirmationDialog(
                LocalizedStringResource("locDeleteYourUnetonAccount", defaultValue: "Delete your Uneton account?", comment: "Text in Settings: Delete your Uneton account?"),
                isPresented: $store.isConfirmingAccountDeletion,
                titleVisibility: .visible
            ) {
                Button(LocalizedStringResource("locDeleteAccount", defaultValue: "Delete account", comment: "Button title in Settings: Delete account"), role: .destructive) {
                    store.send(.deleteAccountButtonTapped)
                }
                Button(LocalizedStringResource("locCancel", defaultValue: "Cancel", comment: "Button title in Settings: Cancel"), role: .cancel) {}
            } message: {
                Text("locThisSignsOutEveryDeviceFamiliesYouOwnTransferToAnotherCaregiverWhenOneIsPresentOtherwiseTheirBabyRecordsAreDeleted", comment: "Text in Settings: This signs out every device. Families you own transfer to another caregiver when one is present; otherwise their baby records are deleted.")
            }
        }
        .presentationDetents([.large])
        .onChange(of: store.isFinished) { _, finished in
            if finished { dismiss() }
        }
    }
}

#if DEBUG
#Preview("Device and account settings") { ScreenFixtures.preview(.familySharingSheet) }
#endif
