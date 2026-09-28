import ComposableArchitecture2
import Foundation
import UnetonCore

@Feature
struct SleepEntry {
    struct State {
        let childID: Child.ID
        let childName: String
        let familyID: Family.ID
        let sessionID: SleepSession.ID?
        var endedAt: Date
        var errorMessage: String?
        var hasEnd: Bool
        var isSaved = false
        var startedAt: Date
        var usesCustomStart: Bool
        @StoreTaskID var save

        init(familyID: Family.ID, childID: Child.ID, childName: String, sessionID: SleepSession.ID? = nil, startedAt: Date = .now, endedAt: Date? = nil) {
            self.childID = childID
            self.childName = childName
            self.familyID = familyID
            self.sessionID = sessionID
            self.startedAt = startedAt
            self.endedAt = endedAt ?? .now
            self.hasEnd = endedAt != nil
            self.usesCustomStart = sessionID != nil
        }

        var validationError: String? {
            if hasEnd && endedAt <= effectiveStart { return "End time must be after start time." }
            if effectiveStart > .now { return "Start time can’t be in the future." }
            return nil
        }

        var effectiveStart: Date { usesCustomStart ? startedAt : .now }
    }

    enum Action {
        case saveButtonTapped
    }

    @FeatureEnvironment(\.sessionDiary) private var sessionDiary

    var body: some Feature {
        Update { state, action in
            switch action {
            case .saveButtonTapped:
                guard state.validationError == nil else { return }
                let familyID = state.familyID
                let childID = state.childID
                let childName = state.childName
                let sessionID = state.sessionID
                let hasEnd = state.hasEnd
                let startedAt = state.effectiveStart
                let endedAt = hasEnd ? state.endedAt : nil
                state.errorMessage = nil
                store.addTask(id: state.save) {
                    let error: String?
                    if sessionID != nil || hasEnd {
                        error = await sessionDiary.logSleep(familyID, childID, sessionID, startedAt, endedAt)
                    } else {
                        error = await sessionDiary.startSleep(familyID, childID, childName, startedAt)
                    }
                    try store.modify {
                        $0.errorMessage = error
                        $0.isSaved = error == nil
                    }
                }
            }
        }
    }
}
