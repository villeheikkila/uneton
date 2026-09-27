import ComposableArchitecture2
import SwiftUI

struct SleepEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: StoreOf<SleepEntry>

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Choose start time", isOn: $store.usesCustomStart)
                    if store.usesCustomStart {
                        DatePicker("Started", selection: $store.startedAt)
                    } else {
                        LabeledContent("Started", value: "Now")
                    }
                    Toggle("Already woke up", isOn: $store.hasEnd)
                    if store.hasEnd {
                        DatePicker("Ended", selection: $store.endedAt, in: (store.usesCustomStart ? store.startedAt : .distantPast)...Date.now)
                    } else {
                        LabeledContent("Status", value: "Still sleeping")
                    }
                }
                if let error = store.validationError ?? store.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
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
                    .disabled(store.validationError != nil || store.save.isRunning)
                }
            }
        }
        .onChange(of: store.isSaved) { _, isSaved in
            if isSaved { dismiss() }
        }
    }
}
