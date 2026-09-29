import ComposableArchitecture2
import SwiftUI

struct GrowthEntryContent: View {
    @Bindable var store: StoreOf<GrowthEntry>

    var body: some View {
        Form {
            Section(LocalizedStringResource("locMeasurement", defaultValue: "Measurement", comment: "Text in Entry: Measurement")) {
                DatePicker(LocalizedStringResource("locDate", defaultValue: "Date", comment: "Picker title in Entry: Date"), selection: $store.measuredAt, displayedComponents: .date)
                TextField(LocalizedStringResource("locWeightKg", defaultValue: "Weight (kg)", comment: "Text field placeholder in Entry: Weight (kg)"), text: $store.weight)
                    .keyboardType(.decimalPad)
                TextField(LocalizedStringResource("locHeightCm", defaultValue: "Height (cm)", comment: "Text field placeholder in Entry: Height (cm)"), text: $store.height)
                    .keyboardType(.decimalPad)
            }
            Section(LocalizedStringResource("locNote", defaultValue: "Note", comment: "Text in Entry: Note")) {
                TextField(LocalizedStringResource("locOptionalNote", defaultValue: "Optional note", comment: "Text field placeholder in Entry: Optional note"), text: $store.note, axis: .vertical)
                    .lineLimit(2...4)
            }
            Section {
                Text("locValuesAreSavedInASharedFamilyRecordTheyAreNotAMedicalAssessmentContactYourNeuvolaOrHealthcareProfessionalWithConcerns", comment: "Text in Entry: Values are saved in a shared family record. They are not a medical assessment; contact your neuvola or healthcare professional with concerns.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = store.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
            if store.measurementID != nil {
                Section {
                    Button(LocalizedStringResource("locDeleteMeasurement", defaultValue: "Delete measurement", comment: "Button title in Entry: Delete measurement"), role: .destructive) {
                        store.send(.deleteButtonTapped)
                    }
                    .disabled(store.request.isRunning)
                }
            }
        }
    }
}
