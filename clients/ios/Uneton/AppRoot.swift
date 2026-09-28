import ComposableArchitecture2
import Foundation
import UnetonCore

@Feature
struct AppRoot {
    struct State {
        var familySetup = FamilySetup.State()
        var familySync: FamilySync.State?
        var isAuthenticated: Bool
        var onboarding = Onboarding.State()
        var selectedFamilyID: Family.ID?
        var selectedChildID: Child.ID?
        var management: FamilyManagement.State?
    }

    enum Action {
        case authenticationChanged(Bool)
        case credentialValidationRequested
        case familySetup(FamilySetup.Action)
        case familySelected(Family.ID?)
        case familySync(FamilySync.Action)
        case onboarding(Onboarding.Action)
        case openedURL(URL)
        case selectFamily(Family.ID)
        case selectChild(Child.ID)
        case showFamilyManagement(Family.ID)
        case management(FamilyManagement.Action)
    }

    @FeatureEnvironment(\.sessionSync) private var sessionSync

    var body: some Feature {
        Features {
            Update { state, action in
                switch action {
                case let .authenticationChanged(isAuthenticated):
                    state.isAuthenticated = isAuthenticated
                    if !isAuthenticated {
                        state.familySync = nil
                        state.selectedFamilyID = nil
                        state.selectedChildID = nil
                        state.management = nil
                    }
                case .credentialValidationRequested:
                    store.addTask {
                        await sessionSync.validateCredential()
                        try store.send(.authenticationChanged(await sessionSync.isAuthenticated()))
                    }
                case let .familySelected(familyID):
                    guard state.isAuthenticated, let familyID else {
                        state.familySync = nil
                        state.selectedFamilyID = nil
                        state.selectedChildID = nil
                        return
                    }
                    if state.selectedFamilyID != familyID {
                        state.selectedFamilyID = familyID
                        state.selectedChildID = nil
                    }
                    if state.familySync?.familyID != familyID {
                        state.familySync = FamilySync.State(familyID: familyID)
                    }
                case let .selectFamily(id):
                    state.selectedFamilyID = id
                    state.selectedChildID = nil
                case let .selectChild(id):
                    state.selectedChildID = id
                case let .showFamilyManagement(id):
                    state.management = FamilyManagement.State(familyID: id)
                case .management:
                    break
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
        .ifLet(\.management) { FamilyManagement() }
    }
}
