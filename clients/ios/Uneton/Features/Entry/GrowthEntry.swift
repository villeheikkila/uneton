import ComposableArchitecture2
import Foundation
import UnetonCore

@Feature
struct GrowthEntry {
    struct State {
        let childID: Child.ID
        let familyID: Family.ID
        let measurementID: GrowthMeasurement.ID?
        var errorMessage: String?
        var height = ""
        var isSaved = false
        var measuredAt: Date
        var note = ""
        var weight = ""
        @StoreTaskID var request

        init(
            familyID: Family.ID,
            childID: Child.ID,
            measurementID: GrowthMeasurement.ID? = nil,
            measuredAt: Date? = nil,
            weightGrams: Int? = nil,
            heightMillimeters: Int? = nil,
            note: String = "",
            now: Date
        ) {
            self.familyID = familyID
            self.childID = childID
            self.measurementID = measurementID
            self.measuredAt = measuredAt ?? now
            self.weight = weightGrams.map { String(format: "%.2f", Double($0) / 1_000) } ?? ""
            self.height = heightMillimeters.map { String(format: "%.1f", Double($0) / 10) } ?? ""
            self.note = note
        }

        var grams: Int? { scaled(weight, multiplier: 1_000) }
        var millimeters: Int? { scaled(height, multiplier: 10) }

        private func scaled(_ value: String, multiplier: Double) -> Int? {
            let normalized = value.replacingOccurrences(of: ",", with: ".")
            guard !normalized.isEmpty, let decimal = Double(normalized) else { return nil }
            return Int((decimal * multiplier).rounded())
        }
    }

    enum Action {
        case deleteButtonTapped
        case saveButtonTapped
    }

    @FeatureEnvironment(\.sessionDiary) private var sessionDiary

    var body: some Feature {
        Update { state, action in
            switch action {
            case .deleteButtonTapped:
                guard let measurementID = state.measurementID else { return }
                let familyID = state.familyID
                state.errorMessage = nil
                store.addTask(id: state.request) {
                    let error = await sessionDiary.deleteGrowth(familyID, measurementID)
                    try store.modify {
                        $0.errorMessage = error
                        $0.isSaved = error == nil
                    }
                }
            case .saveButtonTapped:
                let grams = state.grams
                let millimeters = state.millimeters
                guard grams != nil || millimeters != nil else { return }
                let familyID = state.familyID
                let childID = state.childID
                let measurementID = state.measurementID
                let measuredAt = state.measuredAt
                let note = state.note.trimmingCharacters(in: .whitespacesAndNewlines)
                state.errorMessage = nil
                store.addTask(id: state.request) {
                    let error = await sessionDiary.logGrowth(
                        familyID, childID, measurementID, measuredAt, grams, millimeters, note
                    )
                    try store.modify {
                        $0.errorMessage = error
                        $0.isSaved = error == nil
                    }
                }
            }
        }
    }
}
