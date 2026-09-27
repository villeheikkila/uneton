import ComposableArchitecture2
import Foundation

@Feature
struct AppRoot {
    struct State {
        var familySetup = FamilySetup.State()
        var familySync: FamilySync.State?
        var isAuthenticated: Bool
        var onboarding = Onboarding.State()
    }

    enum Action {
        case authenticationChanged(Bool)
        case credentialValidationRequested
        case familySetup(FamilySetup.Action)
        case familySelected(UUID?)
        case familySync(FamilySync.Action)
        case onboarding(Onboarding.Action)
        case openedURL(URL)
    }

    @FeatureEnvironment(\.sessionSync) private var sessionSync

    var body: some Feature {
        Features {
            Update { state, action in
                switch action {
                case let .authenticationChanged(isAuthenticated):
                    state.isAuthenticated = isAuthenticated
                    if !isAuthenticated { state.familySync = nil }
                case .credentialValidationRequested:
                    store.addTask {
                        await sessionSync.validateCredential()
                        try store.send(.authenticationChanged(await sessionSync.isAuthenticated()))
                    }
                case let .familySelected(familyID):
                    guard state.isAuthenticated, let familyID else {
                        state.familySync = nil
                        return
                    }
                    if state.familySync?.familyID != familyID {
                        state.familySync = FamilySync.State(familyID: familyID)
                    }
                case .familySetup, .familySync, .onboarding:
                    break
                case let .openedURL(url):
                    store.addTask {
                        await sessionSync.handleURL(url)
                        try store.send(.authenticationChanged(await sessionSync.isAuthenticated()))
                    }
                }
            }
            Scope(\.onboarding) {
                Onboarding()
            }
            Scope(\.familySetup) {
                FamilySetup()
            }
        }
        .ifLet(\.familySync) {
            FamilySync()
        }
    }
}
