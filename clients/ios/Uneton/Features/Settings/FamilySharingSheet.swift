import ComposableArchitecture2
import SwiftUI

struct FamilySharingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: StoreOf<FamilySharing>

    var body: some View {
        NavigationStack {
            FamilySharingContent(store: store)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog(
                "Delete your Uneton account?",
                isPresented: $store.isConfirmingAccountDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) {
                    store.send(.deleteAccountButtonTapped)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This signs out every device. Families you own transfer to another caregiver when one is present; otherwise their baby records are deleted.")
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
