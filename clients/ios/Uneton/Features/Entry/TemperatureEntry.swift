import ComposableArchitecture2
import Foundation
import UnetonCore
import UnetonCore

@Feature
struct TemperatureEntry {
    struct State {
        let familyID: Family.ID
        let childID: Child.ID
        let readingID: TemperatureReading.ID?
        var measuredAt: Date
        var temperature: String
        var note: String
        var errorMessage: String?
        var isSaved = false
        @StoreTaskID var request

        init(familyID: Family.ID, childID: Child.ID, readingID: TemperatureReading.ID? = nil,
             measuredAt: Date = .now, centiCelsius: Int? = nil, note: String = "") {
            self.familyID = familyID
            self.childID = childID
            self.readingID = readingID
            self.measuredAt = measuredAt
            self.temperature = centiCelsius.map { String(format: "%.2f", Double($0) / 100) } ?? ""
            self.note = note
        }

        var centiCelsius: Int? {
            TemperatureValue.centiCelsius(from: temperature)
        }
    }

    enum Action { case saveButtonTapped, deleteButtonTapped }

    @FeatureEnvironment(\.sessionDiary) private var sessionDiary

    var body: some Feature {
        Update { state, action in
            switch action {
            case .saveButtonTapped:
                guard let centiCelsius = state.centiCelsius else { return }
                let familyID = state.familyID
                let childID = state.childID
                let readingID = state.readingID
                let measuredAt = state.measuredAt
                let note = state.note.trimmingCharacters(in: .whitespacesAndNewlines)
                state.errorMessage = nil
                store.addTask(id: state.request) {
                    let error = await sessionDiary.logTemperature(familyID, childID, readingID, measuredAt, centiCelsius, note)
                    try store.modify { $0.errorMessage = error; $0.isSaved = error == nil }
                }
            case .deleteButtonTapped:
                guard let readingID = state.readingID else { return }
                let familyID = state.familyID
                state.errorMessage = nil
                store.addTask(id: state.request) {
                    let error = await sessionDiary.deleteTemperature(familyID, readingID)
                    try store.modify { $0.errorMessage = error; $0.isSaved = error == nil }
                }
            }
        }
    }
}
