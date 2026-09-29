import ComposableArchitecture2
import SwiftUI

struct GrowthEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: StoreOf<GrowthEntry>

    var body: some View {
        NavigationStack {
            GrowthEntryContent(store: store)
                .navigationTitle(store.measurementID == nil ? LocalizedStringResource("locAddMeasurement", defaultValue: "Add measurement", comment: "Screen title in Entry: Add measurement") : LocalizedStringResource("locEditMeasurement", defaultValue: "Edit measurement", comment: "Screen title in Entry: Edit measurement"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("locCancel", defaultValue: "Cancel", comment: "Button title in Entry: Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource("locSave", defaultValue: "Save", comment: "Button title in Entry: Save")) {
                        store.send(.saveButtonTapped)
                    }
                    .disabled((store.grams == nil && store.millimeters == nil) || store.request.isRunning)
                }
            }
        }
        .onChange(of: store.isSaved) { _, isSaved in
            if isSaved { dismiss() }
        }
    }
}

#if DEBUG
#Preview("Growth entry sheet") { ScreenFixtures.preview(.growthEntrySheet) }
#endif
