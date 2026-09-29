import ComposableArchitecture2
import UnetonCore
import SwiftUI

extension FamilySync.Tab {
    var systemImage: String {
        switch self {
        case .timeline: "moon.stars.fill"
        case .trends: "chart.xyaxis.line"
        case .growth: "ruler.fill"
        case .temperature: "thermometer.medium"
        }
    }
}

struct TimelineScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var syncStore: StoreOf<FamilySync>
    let family: Family
    let child: Child
    let families: [Family]
    let children: [Child]
    let selectFamily: (Family.ID) -> Void
    let selectChild: (Child.ID) -> Void

    @Namespace private var navigationNamespace

    init(syncStore: StoreOf<FamilySync>, family: Family, child: Child,
         families: [Family] = [], children: [Child] = [],
         selectFamily: @escaping (Family.ID) -> Void = { _ in },
         selectChild: @escaping (Child.ID) -> Void = { _ in }) {
        self.syncStore = syncStore
        self.family = family
        self.child = child
        self.families = families
        self.children = children
        self.selectFamily = selectFamily
        self.selectChild = selectChild
    }

    var body: some View {
        NavigationStack {
            TimelineContent(syncStore: syncStore, child: child,
                navigationNamespace: navigationNamespace)
                .navigationTitle(child.nickname)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu("Family", systemImage: "person.2.fill") {
                            if families.count > 1 {
                                Section("Families") {
                                    ForEach(families) { item in
                                        Button(item.name, systemImage: item.id == family.id ? "checkmark" : "house") {
                                            selectFamily(item.id)
                                        }
                                    }
                                }
                            }
                            if children.count > 1 {
                                Section("Babies") {
                                    ForEach(children) { item in
                                        Button(item.nickname, systemImage: item.id == child.id ? "checkmark" : "figure.child") {
                                            selectChild(item.id)
                                        }
                                    }
                                }
                            }
                            Button("Manage family", systemImage: "person.2") {
                                syncStore.send(.familyButtonTapped)
                            }
                        }
                    }

                    if !syncStore.conflicts.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Sync conflicts", systemImage: "exclamationmark.triangle.fill") {
                                syncStore.send(.conflictListButtonTapped)
                            }
                            .tint(.orange)
                        }
                    }
                }
            .sheet(item: $syncStore.scope(\.entry)) { entryStore in
                SleepEntrySheet(store: entryStore)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $syncStore.scope(\.sharing)) { sharingStore in
                FamilySharingSheet(store: sharingStore)
            }
            .sheet(item: $syncStore.scope(\.management)) { managementStore in
                FamilyManagementSheet(store: managementStore)
            }
            .sheet(isPresented: $syncStore.isPresentingConflicts) {
                SyncConflictsSheet(conflicts: syncStore.conflicts, syncStore: syncStore)
            }
            .sheet(item: $syncStore.scope(\.growthEntry)) { entryStore in
                GrowthEntrySheet(store: entryStore)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $syncStore.scope(\.temperatureEntry)) { entryStore in
                TemperatureEntrySheet(store: entryStore)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .task(id: scenePhase) {
                syncStore.send(.foregroundChanged(scenePhase == .active))
            }
            .refreshable {
                await syncStore.send(.refreshRequested)?.value
            }
            .safeAreaInset(edge: .bottom) {
                if let error = syncStore.errorMessage, !syncStore.isPresentingConflicts {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
        }
    }
}

#if DEBUG
#Preview("Sleep tab") { ScreenFixtures.preview(.sleepTab) }
#Preview("Growth tab") { ScreenFixtures.preview(.growthTab) }
#Preview("Temperature tab") { ScreenFixtures.preview(.temperatureTab) }
#Preview("Growth entry sheet") { ScreenFixtures.preview(.growthEntrySheet) }
#endif
