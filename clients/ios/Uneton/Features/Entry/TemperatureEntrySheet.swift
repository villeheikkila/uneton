import ComposableArchitecture2
import SwiftUI

struct TemperatureEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: StoreOf<TemperatureEntry>

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading") {
                    DatePicker("Measured", selection: $store.measuredAt, in: ...Date.now)
                    TextField("Temperature (°C)", text: $store.temperature)
                        .keyboardType(.decimalPad)
                }
                Section("Note") {
                    TextField("Optional note", text: $store.note, axis: .vertical).lineLimit(2...4)
                }
                Section {
                    Text("This is a shared observation, not a medical assessment. Contact a healthcare professional if you have concerns.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = store.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                if store.readingID != nil {
                    Section {
                        Button("Delete reading", role: .destructive) { store.send(.deleteButtonTapped) }
                            .disabled(store.request.isRunning)
                    }
                }
            }
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
