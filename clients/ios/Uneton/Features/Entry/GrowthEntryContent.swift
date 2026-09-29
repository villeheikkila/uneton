import ComposableArchitecture2
import SwiftUI

struct GrowthEntryContent: View {
    @Bindable var store: StoreOf<GrowthEntry>

    var body: some View {
        Form {
            Section("Measurement") {
                DatePicker("Date", selection: $store.measuredAt, displayedComponents: .date)
                TextField("Weight (kg)", text: $store.weight)
                    .keyboardType(.decimalPad)
                TextField("Height (cm)", text: $store.height)
                    .keyboardType(.decimalPad)
            }
            Section("Note") {
                TextField("Optional note", text: $store.note, axis: .vertical)
                    .lineLimit(2...4)
            }
            Section {
                Text("Values are saved in a shared family record. They are not a medical assessment; contact your neuvola or healthcare professional with concerns.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = store.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
            if store.measurementID != nil {
                Section {
                    Button("Delete measurement", role: .destructive) {
                        store.send(.deleteButtonTapped)
                    }
                    .disabled(store.request.isRunning)
                }
            }
        }
    }
}
