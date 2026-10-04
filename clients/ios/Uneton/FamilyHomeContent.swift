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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .skyBackground()
                }
            } else if homeStore.isLoadingChildren {
                ProgressView(LocalizedStringResource("locLoadingBabies", defaultValue: "Loading babies…", comment: "Text in FamilyHome: Loading babies…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .skyBackground()
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
            ContentUnavailableView(LocalizedStringResource("locNoBabiesYet", defaultValue: "No babies yet", comment: "Text in FamilyHome: No babies yet"), systemImage: "figure.child",
                description: Text("locAddABabyToStartTrackingSleepGrowthAndTemperature", comment: "Text in FamilyHome: Add a baby to start tracking sleep, growth and temperature."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .skyBackground()
                .navigationTitle(family.name)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu(LocalizedStringResource("locFamily", defaultValue: "Family", comment: "Text in FamilyHome: Family"), systemImage: "person.2.fill") {
                            ForEach(families) { item in
                                Button(item.name) { store.send(.selectFamily(item.id)) }
                            }
                            Button(LocalizedStringResource("locManageFamily", defaultValue: "Manage family", comment: "Button title in FamilyHome: Manage family")) { store.send(.showFamilyManagement(family.id)) }
                        }
                    }
                }
                .safeAreaBar(edge: .bottom) {
                    Button(LocalizedStringResource("locAddBaby", defaultValue: "Add baby", comment: "Button title in FamilyHome: Add baby"), systemImage: "plus") { store.send(.showFamilyManagement(family.id)) }
                        .buttonStyle(.glassProminent)
                }
                .sheet(item: $store.scope(\.management)) { management in
                    FamilyManagementSheet(store: management)
                }
        }
    }
}
