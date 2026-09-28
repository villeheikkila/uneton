import ComposableArchitecture2
import UnetonCore
import SQLiteData
import SwiftUI

struct ContentView: View {
    private struct Selection: Equatable {
        let familyID: Family.ID?
        let isAuthenticated: Bool
    }

    @Bindable var store: StoreOf<AppRoot>
    @Environment(SessionStore.self) private var session
    @FetchAll(Family.order { $0.updatedAt.desc() }) private var families
    @FetchAll(Child.order { $0.updatedAt.desc() }) private var children

    private var visibleFamilies: [Family] {
        guard let memberships = session.memberships else { return families }
        let ids = Set(memberships.map(\.id))
        return families.filter { ids.contains($0.id) }
    }

    private var selectedFamily: Family? {
        visibleFamilies.first { $0.id == store.selectedFamilyID } ?? visibleFamilies.first
    }

    var body: some View {
        Group {
            if !store.isAuthenticated {
                OnboardingView(
                    store: store.scope(\.onboarding),
                    prepareAppleAuthorization: { session.prepareAppleAuthorization($0) }
                )
            } else if let family = selectedFamily {
                let familyChildren = children.filter { $0.familyID == family.id }
                if let child = familyChildren.first(where: { $0.id == store.selectedChildID }) ?? familyChildren.first {
                    familyContent(family: family, child: child, familyChildren: familyChildren)
                } else {
                    emptyFamily(family)
                }
            } else {
                FamilySetupView(store: store.scope(\.familySetup))
            }
        }
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

    @ViewBuilder
    private func familyContent(family: Family, child: Child, familyChildren: [Child]) -> some View {
        if let syncStore = store.scope(\.familySync) {
            TimelineScreen(syncStore: syncStore, family: family, child: child,
                families: visibleFamilies, children: familyChildren,
                selectFamily: { store.send(.selectFamily($0)) },
                selectChild: { store.send(.selectChild($0)) })
        } else {
            ProgressView()
        }
    }

    private func emptyFamily(_ family: Family) -> some View {
        NavigationStack {
            ContentUnavailableView("No babies yet", systemImage: "figure.child",
                description: Text("Add a baby to start tracking sleep, growth and temperature."))
                .navigationTitle(family.name)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu("Family", systemImage: "person.2.fill") {
                            ForEach(visibleFamilies) { item in
                                Button(item.name) { store.send(.selectFamily(item.id)) }
                            }
                            Button("Manage family") { store.send(.showFamilyManagement(family.id)) }
                        }
                    }
                }
                .safeAreaBar(edge: .bottom) {
                    Button("Add baby", systemImage: "plus") { store.send(.showFamilyManagement(family.id)) }
                        .buttonStyle(.glassProminent)
                }
                .sheet(item: $store.scope(\.management)) { management in
                    FamilyManagementView(store: management, children: [])
                }
        }
    }
}
