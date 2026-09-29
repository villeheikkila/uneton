import ComposableArchitecture2
import SwiftUI

struct SleepEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: StoreOf<SleepEntry>

    var body: some View {
        NavigationStack {
            SleepEntryContent(store: store)
                .navigationTitle(store.sessionID == nil ? (store.hasEnd ? "Log sleep" : "Start sleep") : "Edit sleep")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.sessionID == nil ? (store.hasEnd ? "Add" : "Start") : "Save") {
                        store.send(.saveButtonTapped)
                    }
                    .disabled(store.save.isRunning)
                }
            }
        }
        .onChange(of: store.isSaved) { _, isSaved in
            if isSaved { dismiss() }
        }
    }
}

#if DEBUG
#Preview("Sleep entry sheet") { ScreenFixtures.preview(.sleepEntrySheet) }
#endif
