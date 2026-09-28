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
        let openedAt: Date
        @StoreTaskID var save

        init(familyID: Family.ID, childID: Child.ID, childName: String, sessionID: SleepSession.ID? = nil, startedAt: Date? = nil, endedAt: Date? = nil, now: Date) {
            self.childID = childID
            self.childName = childName
            self.familyID = familyID
            self.sessionID = sessionID
            self.startedAt = startedAt ?? now
            self.endedAt = endedAt ?? now
            self.openedAt = now
            self.hasEnd = endedAt != nil
            self.usesCustomStart = sessionID != nil
        }

        var validationError: String? {
            validationError(at: openedAt)
        }

        func validationError(at now: Date) -> String? {
            if hasEnd && endedAt <= effectiveStart(at: now) { return "End time must be after start time." }
            if effectiveStart(at: now) > now { return "Start time can’t be in the future." }
            return nil
        }

        func effectiveStart(at now: Date) -> Date { usesCustomStart ? startedAt : now }
    }

    enum Action {
        case saveButtonTapped
    }

    @FeatureEnvironment(\.sessionDiary) private var sessionDiary
    @FeatureEnvironment(\.date.now) private var now

    var body: some Feature {
        Update { state, action in
            switch action {
            case .saveButtonTapped:
                let submittedAt = now
                if let error = state.validationError(at: submittedAt) {
                    state.errorMessage = error
                    return
                }
                let familyID = state.familyID
                let childID = state.childID
                let childName = state.childName
                let sessionID = state.sessionID
                let hasEnd = state.hasEnd
                let startedAt = state.effectiveStart(at: submittedAt)
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
