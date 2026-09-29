import ComposableArchitecture2
import SwiftUI

struct AddChildSheet: View {
    @Bindable var store: StoreOf<FamilyManagement>

    var body: some View {
        NavigationStack {
            AddChildContent(store: store)
                .navigationTitle(LocalizedStringResource("locAddBaby", defaultValue: "Add baby", comment: "Screen title in FamilyManagement: Add baby"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(LocalizedStringResource("locCancel", defaultValue: "Cancel", comment: "Button title in FamilyManagement: Cancel")) { store.send(.dismissAddChild) }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(LocalizedStringResource("locAdd", defaultValue: "Add", comment: "Button title in FamilyManagement: Add")) { store.send(.saveNewChild) }
                            .disabled(store.request.isRunning
                                || store.newChildName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
