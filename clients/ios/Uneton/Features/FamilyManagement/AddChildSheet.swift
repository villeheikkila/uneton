import ComposableArchitecture2
import SwiftUI

struct AddChildSheet: View {
    @Bindable var store: StoreOf<FamilyManagement>

    var body: some View {
        NavigationStack {
            AddChildContent(store: store)
                .navigationTitle("Add baby")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { store.send(.dismissAddChild) }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { store.send(.saveNewChild) }
                            .disabled(store.request.isRunning
                                || store.newChildName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
