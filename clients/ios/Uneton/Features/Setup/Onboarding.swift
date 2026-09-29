import AuthenticationServices
import ComposableArchitecture2
import Foundation

@Feature
struct Onboarding {
    struct State {
        var caregiverName = String(localized: LocalizedStringResource("locCaregiver", defaultValue: "Caregiver", comment: "Message in Setup: Caregiver"))
        var errorMessage: String?
        @StoreTaskID var signIn
    }

    enum Action {
        case appleAuthorizationCompleted(Result<ASAuthorization, any Error>)
        case developmentSignInButtonTapped
    }

    @FeatureEnvironment(\.sessionAuth) private var sessionAuth

    var body: some Feature {
        Update { state, action in
            switch action {
            case let .appleAuthorizationCompleted(result):
                state.errorMessage = nil
                store.addTask(id: state.signIn) {
                    let error = await sessionAuth.completeAppleAuthorization(result)
                    try store.modify { $0.errorMessage = error }
                }
            case .developmentSignInButtonTapped:
                let name = state.caregiverName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                state.errorMessage = nil
                store.addTask(id: state.signIn) {
                    let error = await sessionAuth.developmentAuthenticate(name)
                    try store.modify { $0.errorMessage = error }
                }
            }
        }
    }
}
