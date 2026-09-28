import ComposableArchitecture2
import Foundation

@Feature
struct TemperatureEntry {
    struct State {
        let familyID: UUID
        let childID: UUID
        let readingID: UUID?
        var measuredAt: Date
        var temperature: String
        var note: String
        var errorMessage: String?
        var isSaved = false
        @StoreTaskID var request

        init(familyID: UUID, childID: UUID, readingID: UUID? = nil,
             measuredAt: Date = .now, centiCelsius: Int? = nil, note: String = "") {
            self.familyID = familyID
            self.childID = childID
            self.readingID = readingID
            self.measuredAt = measuredAt
            self.temperature = centiCelsius.map { String(format: "%.2f", Double($0) / 100) } ?? ""
            self.note = note
        }

        var centiCelsius: Int? {
            let normalized = temperature.replacingOccurrences(of: ",", with: ".")
            guard let value = Double(normalized), value.isFinite, (20...50).contains(value) else { return nil }
            return Int((value * 100).rounded())
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
