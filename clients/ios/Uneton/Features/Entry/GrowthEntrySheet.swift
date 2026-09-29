import ComposableArchitecture2
import SwiftUI

struct GrowthEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: StoreOf<GrowthEntry>

    var body: some View {
        NavigationStack {
            GrowthEntryContent(store: store)
                .navigationTitle(store.measurementID == nil ? "Add measurement" : "Edit measurement")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
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
