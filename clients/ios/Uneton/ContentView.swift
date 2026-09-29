import ComposableArchitecture2
import UnetonCore
import SwiftUI

struct ContentView: View {
    private struct Selection: Equatable {
        let familyID: Family.ID?
        let isAuthenticated: Bool
    }

    @Bindable var store: StoreOf<AppRoot>
    @Environment(SessionStore.self) private var session
    private var visibleFamilies: [Family] {
        guard let memberships = session.memberships else { return store.families }
        let ids = Set(memberships.map(\.id))
        return store.families.filter { ids.contains($0.id) }
    }

    private var selectedFamily: Family? {
        visibleFamilies.first { $0.id == store.selectedFamilyID } ?? visibleFamilies.first
    }

    var body: some View {
        Group {
            if !store.isAuthenticated {
                OnboardingScreen(
                    store: store.scope(\.onboarding),
                    prepareAppleAuthorization: { session.prepareAppleAuthorization($0) }
                )
            } else if let family = selectedFamily {
                if let homeStore = store.scope(\.familyHome), homeStore.familyID == family.id {
                    FamilyHomeContent(store: store, homeStore: homeStore, family: family,
                        families: visibleFamilies)
                        .id(family.id)
                } else {
                    ProgressView()
                }
            } else {
                FamilySetupScreen(store: store.scope(\.familySetup))
            }
        }
        .tint(Color.sleepBlue)
        .onOpenURL { url in
            store.send(.openedURL(url))
        }
        .task { store.send(.credentialValidationRequested) }
        .task(id: Selection(familyID: selectedFamily?.id, isAuthenticated: store.isAuthenticated)) {
            store.send(.familySelected(selectedFamily?.id))
        }
        .onChange(of: session.isAuthenticated) { _, authenticated in
            store.send(.authenticationChanged(authenticated))
        }
    }

}
