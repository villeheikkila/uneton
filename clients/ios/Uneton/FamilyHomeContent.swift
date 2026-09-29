import ComposableArchitecture2
import SwiftUI
import UnetonCore

struct FamilyHomeContent: View {
    @Bindable var store: StoreOf<AppRoot>
    let homeStore: StoreOf<FamilyHome>
    let family: Family
    let families: [Family]

    private var selectedChild: Child? {
        homeStore.children.first(where: { $0.id == store.selectedChildID }) ?? homeStore.children.first
    }

    var body: some View {
        Group {
            if let child = selectedChild {
                if let syncStore = store.scope(\.familySync),
                   syncStore.familyID == family.id, syncStore.childID == child.id {
                    TimelineScreen(syncStore: syncStore, family: family, child: child,
                        families: families, children: homeStore.children,
                        selectFamily: { store.send(.selectFamily($0)) },
                        selectChild: { store.send(.selectChild($0)) })
                        .id(child.id)
                } else {
                    ProgressView()
                }
            } else if homeStore.isLoadingChildren {
                ProgressView("Loading babies…")
            } else {
                emptyFamily
            }
        }
        .task(id: selectedChild?.id) {
            guard let child = selectedChild else { return }
            if store.selectedChildID != child.id || store.familySync?.childID != child.id {
                store.send(.selectChild(child.id))
            }
        }
    }

    private var emptyFamily: some View {
        NavigationStack {
            ContentUnavailableView("No babies yet", systemImage: "figure.child",
                description: Text("Add a baby to start tracking sleep, growth and temperature."))
                .navigationTitle(family.name)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu("Family", systemImage: "person.2.fill") {
                            ForEach(families) { item in
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
                    FamilyManagementSheet(store: management)
                }
        }
    }
}
