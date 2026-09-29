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
                ToolbarItem(placement: .cancellationAction) { Button(LocalizedStringResource("locCancel", defaultValue: "Cancel", comment: "Button title in FamilyManagement: Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource("locSave", defaultValue: "Save", comment: "Button title in FamilyManagement: Save")) { store.send(.save) }
                        .disabled(store.request.isRunning || store.validationMessage != nil)
                }
            }
            .confirmationDialog(.locDeleteChildQuestion(store.child.nickname), isPresented: $store.isConfirmingDeletion) {
                Button(LocalizedStringResource("locDeleteBabyAndRecords", defaultValue: "Delete baby and records", comment: "Button title in FamilyManagement: Delete baby and records"), role: .destructive) { store.send(.delete) }
                Button(LocalizedStringResource("locCancel", defaultValue: "Cancel", comment: "Button title in FamilyManagement: Cancel"), role: .cancel) {}
            } message: { Text("locThisRemovesThisBabySSleepGrowthAndTemperatureRecordsForEveryoneInTheFamily", comment: "Text in FamilyManagement: This removes this baby’s sleep, growth and temperature records for everyone in the family.") }
        }
        .onChange(of: store.isFinished) { _, finished in if finished { dismiss() } }
    }
}

#if DEBUG
#Preview("Baby settings") { ScreenFixtures.preview(.childEditorSheet) }
#endif
