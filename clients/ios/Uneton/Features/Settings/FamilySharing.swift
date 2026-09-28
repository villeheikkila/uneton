import ComposableArchitecture2
import Foundation

@Feature
struct FamilySharing {
    struct State {
        var errorMessage: String?
        var isConfirmingAccountDeletion = false
        var isFinished = false
        var liveActivitiesEnabled: Bool
        var notificationsEnabled: Bool
        var reminderLeadMinutes: Int
        @StoreTaskID var accountRequest

        init(notificationsEnabled: Bool, liveActivitiesEnabled: Bool, reminderLeadMinutes: Int) {
            self.notificationsEnabled = notificationsEnabled
            self.liveActivitiesEnabled = liveActivitiesEnabled
            self.reminderLeadMinutes = reminderLeadMinutes
        }
    }

    enum Action {
        case deleteAccountButtonTapped
        case deleteAccountPromptButtonTapped
        case signOutButtonTapped
    }

    @FeatureEnvironment(\.sessionSharing) private var sessionSharing

    var body: some Feature {
        Update { state, action in
            switch action {
            case .deleteAccountButtonTapped:
                state.errorMessage = nil
                store.addTask(id: state.accountRequest) {
                    let (succeeded, error) = await sessionSharing.deleteAccount()
                    try store.modify {
                        $0.errorMessage = error
                        $0.isFinished = succeeded
                    }
                }
            case .deleteAccountPromptButtonTapped:
                state.isConfirmingAccountDeletion = true
            case .signOutButtonTapped:
                state.errorMessage = nil
                store.addTask(id: state.accountRequest) {
                    let (succeeded, error) = await sessionSharing.signOut()
                    try store.modify {
                        $0.errorMessage = error
                        $0.isFinished = succeeded
                    }
                }
            }
        }
        .onChange(of: store.liveActivitiesEnabled) { state in
            let enabled = state.liveActivitiesEnabled
            store.addTask { await sessionSharing.setLiveActivitiesEnabled(enabled) }
        }
        .onChange(of: store.notificationsEnabled) { state in
            let enabled = state.notificationsEnabled
            store.addTask { await sessionSharing.setNotificationsEnabled(enabled) }
        }
        .onChange(of: store.reminderLeadMinutes) { state in
            let minutes = state.reminderLeadMinutes
            store.addTask { await sessionSharing.setReminderLeadMinutes(minutes) }
        }
    }
}
