import ComposableArchitecture2
import Foundation
import Observation
import SQLiteData
import UnetonCore

@Feature
struct AppRoot {
    struct State {
        @ObservationIgnored @DebugSnapshotIgnored @FetchAll(Family.order { $0.updatedAt.desc() }) var families: [Family]
        var familyHome: FamilyHome.State?
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
        case familyHome(FamilyHome.Action)
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
                        state.familyHome = nil
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
                        state.familyHome = nil
                        state.selectedFamilyID = nil
                        state.selectedChildID = nil
                        return
                    }
                    if state.selectedFamilyID != familyID {
                        state.selectedFamilyID = familyID
                        state.selectedChildID = nil
                    }
                    if state.familyHome?.familyID != familyID {
                        state.familyHome = FamilyHome.State(familyID: familyID)
                    }
                    if let childID = state.selectedChildID {
                        if state.familySync?.familyID != familyID || state.familySync?.childID != childID {
                            state.familySync = FamilySync.State(familyID: familyID, childID: childID)
                        }
                    } else {
                        state.familySync = nil
                    }
                case let .selectFamily(id):
                    state.selectedFamilyID = id
                    state.selectedChildID = nil
                    state.familyHome = FamilyHome.State(familyID: id)
                    state.familySync = nil
                case let .selectChild(id):
                    state.selectedChildID = id
                    if let familyID = state.selectedFamilyID,
                       (state.familySync?.familyID != familyID || state.familySync?.childID != id) {
                        let selectedTab = state.familySync?.selectedTab ?? .timeline
                        state.familySync = FamilySync.State(familyID: familyID, childID: id)
                        state.familySync?.selectedTab = selectedTab
                    }
                case let .showFamilyManagement(id):
                    state.management = FamilyManagement.State(familyID: id)
                case .management:
                    break
                case .familyHome, .familySetup, .familySync, .onboarding:
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
        .ifLet(\.familyHome) { FamilyHome() }
        .ifLet(\.familySync) {
            FamilySync()
        }
        .ifLet(\.management) { FamilyManagement() }
    }
}
