import ComposableArchitecture2
import SwiftUI

struct TemperatureEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: StoreOf<TemperatureEntry>

    var body: some View {
        NavigationStack {
            TemperatureEntryContent(store: store)
                .navigationTitle(store.readingID == nil ? LocalizedStringResource("locAddTemperature", defaultValue: "Add temperature", comment: "Screen title in Entry: Add temperature") : LocalizedStringResource("locEditTemperature", defaultValue: "Edit temperature", comment: "Screen title in Entry: Edit temperature"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(LocalizedStringResource("locCancel", defaultValue: "Cancel", comment: "Button title in Entry: Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource("locSave", defaultValue: "Save", comment: "Button title in Entry: Save")) { store.send(.saveButtonTapped) }
                        .disabled(store.centiCelsius == nil || store.request.isRunning)
                }
            }
        }
        .onChange(of: store.isSaved) { _, isSaved in if isSaved { dismiss() } }
    }
}
