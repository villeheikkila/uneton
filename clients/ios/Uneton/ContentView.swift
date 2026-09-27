import ComposableArchitecture2
import Dependencies
import UnetonCore
import SQLiteData
import SwiftUI

struct ContentView: View {
    private struct Selection: Equatable {
        let familyID: UUID?
        let isAuthenticated: Bool
    }

    let store: StoreOf<AppRoot>
    @Environment(SessionStore.self) private var session
    @FetchAll(Family.order { $0.updatedAt.desc() }) private var families
    @FetchAll(Child.order { $0.updatedAt.desc() }) private var children

    var body: some View {
        Group {
            if !store.isAuthenticated {
                OnboardingView(
                    store: store.scope(\.onboarding),
                    prepareAppleAuthorization: { session.prepareAppleAuthorization($0) }
                )
            } else if let family = families.first,
               let child = children.first(where: { $0.familyID == family.id }) {
                familyContent(family: family, child: child)
            } else {
                FamilySetupView(store: store.scope(\.familySetup))
            }
        }
        .onOpenURL { url in
            store.send(.openedURL(url))
        }
        .task { store.send(.credentialValidationRequested) }
        .task(id: Selection(familyID: families.first?.id, isAuthenticated: store.isAuthenticated)) {
            store.send(.familySelected(families.first?.id))
        }
        .onChange(of: session.isAuthenticated) { _, authenticated in
            store.send(.authenticationChanged(authenticated))
        }
    }

    @ViewBuilder
    private func familyContent(family: Family, child: Child) -> some View {
        if let syncStore = store.scope(\.familySync) {
            TimelineScreen(syncStore: syncStore, family: family, child: child)
        } else {
            ProgressView()
        }
    }
}

#Preview {
    let _ = prepareDependencies {
        try! $0.bootstrapDatabase()
    }
    let session = SessionStore()
    ContentView(store: Store(initialState: AppRoot.State(isAuthenticated: session.isAuthenticated)) {
        AppRoot()
            .environment(\.sessionSync, .live(session: session))
            .environment(\.sessionAuth, .live(session: session))
            .environment(\.sessionFamily, .live(session: session))
            .environment(\.sessionDiary, .live(session: session))
            .environment(\.sessionSharing, .live(session: session))
    })
        .environment(session)
}
