import ComposableArchitecture2
import SwiftUI

struct ChildEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: StoreOf<ChildEditor>

    var body: some View {
        NavigationStack {
            ChildEditorContent(store: store)
                .navigationTitle(store.child.nickname)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.save) }
                        .disabled(store.request.isRunning || store.validationMessage != nil)
                }
            }
            .confirmationDialog("Delete \(store.child.nickname)?", isPresented: $store.isConfirmingDeletion) {
                Button("Delete baby and records", role: .destructive) { store.send(.delete) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes this baby’s sleep, growth and temperature records for everyone in the family.") }
        }
        .onChange(of: store.isFinished) { _, finished in if finished { dismiss() } }
    }
}

#if DEBUG
#Preview("Baby settings") { ScreenFixtures.preview(.childEditorSheet) }
#endif
