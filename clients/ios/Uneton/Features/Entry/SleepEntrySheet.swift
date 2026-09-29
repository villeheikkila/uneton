import ComposableArchitecture2
import SwiftUI

struct SleepEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: StoreOf<SleepEntry>

    var body: some View {
        NavigationStack {
            SleepEntryContent(store: store)
                .navigationTitle(store.sessionID == nil ? (store.hasEnd ? LocalizedStringResource("locLogSleep", defaultValue: "Log sleep", comment: "Screen title in Entry: Log sleep") : LocalizedStringResource("locStartSleep", defaultValue: "Start sleep", comment: "Screen title in Entry: Start sleep")) : LocalizedStringResource("locEditSleep", defaultValue: "Edit sleep", comment: "Screen title in Entry: Edit sleep"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringResource("locCancel", defaultValue: "Cancel", comment: "Button title in Entry: Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.sessionID == nil ? (store.hasEnd ? LocalizedStringResource("locAdd", defaultValue: "Add", comment: "Button title in Entry: Add") : LocalizedStringResource("locStart", defaultValue: "Start", comment: "Button action that starts a new sleep session")) : LocalizedStringResource("locSave", defaultValue: "Save", comment: "Button title in Entry: Save")) {
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
