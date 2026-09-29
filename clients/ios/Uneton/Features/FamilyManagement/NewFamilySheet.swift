import ComposableArchitecture2
import SwiftUI

struct NewFamilySheet: View {
    @Bindable var store: StoreOf<FamilyManagement>

    var body: some View {
        NavigationStack {
            NewFamilyContent(store: store)
                .navigationTitle("New family")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { store.send(.dismissCreateFamily) }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { store.send(.saveNewFamily) }
                            .disabled(store.request.isRunning
                                || store.newFamilyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
