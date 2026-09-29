import ComposableArchitecture2
import SwiftUI

struct NewFamilySheet: View {
    @Bindable var store: StoreOf<FamilyManagement>

    var body: some View {
        NavigationStack {
            NewFamilyContent(store: store)
                .navigationTitle(LocalizedStringResource("locNewFamily", defaultValue: "New family", comment: "Screen title in FamilyManagement: New family"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(LocalizedStringResource("locCancel", defaultValue: "Cancel", comment: "Button title in FamilyManagement: Cancel")) { store.send(.dismissCreateFamily) }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(LocalizedStringResource("locCreate", defaultValue: "Create", comment: "Button title in FamilyManagement: Create")) { store.send(.saveNewFamily) }
                            .disabled(store.request.isRunning
                                || store.newFamilyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
