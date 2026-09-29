import ComposableArchitecture2
import SwiftUI

struct TemperatureEntryContent: View {
    @Bindable var store: StoreOf<TemperatureEntry>

    var body: some View {
        Form {
            Section(LocalizedStringResource("locReading", defaultValue: "Reading", comment: "Text in Entry: Reading")) {
                DatePicker(LocalizedStringResource("locMeasured", defaultValue: "Measured", comment: "Picker title in Entry: Measured"), selection: $store.measuredAt, in: ...Date.now)
                TextField(LocalizedStringResource("locTemperatureC", defaultValue: "Temperature (°C)", comment: "Text field placeholder in Entry: Temperature (°C)"), text: $store.temperature)
                    .keyboardType(.decimalPad)
            }
            Section(LocalizedStringResource("locNote", defaultValue: "Note", comment: "Text in Entry: Note")) {
                TextField(LocalizedStringResource("locOptionalNote", defaultValue: "Optional note", comment: "Text field placeholder in Entry: Optional note"), text: $store.note, axis: .vertical).lineLimit(2...4)
            }
            Section {
                Text("locThisIsASharedObservationNotAMedicalAssessmentContactAHealthcareProfessionalIfYouHaveConcerns", comment: "Text in Entry: This is a shared observation, not a medical assessment. Contact a healthcare professional if you have concerns.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = store.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            if store.readingID != nil {
                Section {
                    Button(LocalizedStringResource("locDeleteReading", defaultValue: "Delete reading", comment: "Button title in Entry: Delete reading"), role: .destructive) { store.send(.deleteButtonTapped) }
                        .disabled(store.request.isRunning)
                }
            }
        }
    }
}
