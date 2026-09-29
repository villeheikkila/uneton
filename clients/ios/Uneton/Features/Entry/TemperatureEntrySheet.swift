import ComposableArchitecture2
import SwiftUI

struct TemperatureEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: StoreOf<TemperatureEntry>

    var body: some View {
        NavigationStack {
            TemperatureEntryContent(store: store)
                .navigationTitle(store.readingID == nil ? "Add temperature" : "Edit temperature")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.saveButtonTapped) }
                        .disabled(store.centiCelsius == nil || store.request.isRunning)
                }
            }
        }
        .onChange(of: store.isSaved) { _, isSaved in if isSaved { dismiss() } }
    }
}
