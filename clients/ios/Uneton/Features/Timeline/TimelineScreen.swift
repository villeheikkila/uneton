import ComposableArchitecture2
import UnetonCore
import SwiftUI
import UnetonTheme

extension FamilySync.Tab {
    var title: LocalizedStringResource {
        switch self {
        case .timeline: LocalizedStringResource("locSleep", defaultValue: "Sleep", comment: "Main tab titles for sleep, insights, growth, and temperature")
        case .trends: LocalizedStringResource("locInsights", defaultValue: "Insights", comment: "Main navigation tab for charts and sleep summaries")
        case .growth: LocalizedStringResource("locGrowth", defaultValue: "Growth", comment: "Text in Timeline: Growth")
        case .temperature: LocalizedStringResource("locTemperature", defaultValue: "Temperature", comment: "Temperature tracking tab or Watch screen title; this is body temperature")
        }
    }

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

    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.calendar) private var calendar
    @AppStorage("nightLightEnabled") private var nightLightEnabled = false

    private var nightSleepActive: Bool {
        syncStore.activeSession.map { SleepKind(startedAt: $0.startedAt, calendar: calendar) == .night } ?? false
    }

    /// Every child uses the sky seed until a per-child color setting exists.
    private var palette: Palette {
        Palette.make(seed: .sky, mode: SleepAppearance.mode(
            nightSleepActive: nightSleepActive,
            prefersDark: systemColorScheme == .dark,
            nightLightEnabled: nightLightEnabled
        ))
    }

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
            TimelineContent(syncStore: syncStore, child: child)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            if families.count > 1 {
                                Section(LocalizedStringResource("locFamilies", defaultValue: "Families", comment: "Text in Timeline: Families")) {
                                    ForEach(families) { item in
                                        Button(item.name, systemImage: item.id == family.id ? "checkmark" : "house") {
                                            selectFamily(item.id)
                                        }
                                    }
                                }
                            }
                            if children.count > 1 {
                                Section(LocalizedStringResource("locBabies", defaultValue: "Babies", comment: "Text in Timeline: Babies")) {
                                    ForEach(children) { item in
                                        Button(item.nickname, systemImage: item.id == child.id ? "checkmark" : "figure.child") {
                                            selectChild(item.id)
                                        }
                                    }
                                }
                            }
                            Button(LocalizedStringResource("locManageFamily", defaultValue: "Manage family", comment: "Button title in Timeline: Manage family"), systemImage: "person.2") {
                                syncStore.send(.familyButtonTapped)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(child.nickname)
                                    .font(.soft(17))
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.heavy))
                            }
                            .foregroundStyle(palette.ink.color)
                        }
                        .accessibilityLabel(LocalizedStringResource("locFamily", defaultValue: "Family", comment: "Text in Timeline: Family"))
                        .accessibilityValue(child.nickname)
                    }

                    if nightSleepActive {
                        ToolbarItem(placement: .topBarTrailing) {
                            Toggle(isOn: $nightLightEnabled) {
                                Label(LocalizedStringResource("locNightLight", defaultValue: "Night light", comment: "Toggle for a very dim amber screen while the baby sleeps at night"), systemImage: nightLightEnabled ? "lightbulb.min.fill" : "lightbulb.min")
                            }
                            .toggleStyle(.button)
                            .tint(palette.wake.color)
                        }
                    }

                    if syncStore.selectedTab == .growth {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(LocalizedStringResource("locAddMeasurement", defaultValue: "Add measurement", comment: "Label in Timeline: Add measurement"), systemImage: "plus") {
                                syncStore.send(.newGrowthMeasurementButtonTapped(child.id))
                            }
                        }
                    }

                    if syncStore.selectedTab == .temperature {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(LocalizedStringResource("locAddTemperature", defaultValue: "Add temperature", comment: "Label in Timeline: Add temperature"), systemImage: "plus") {
                                syncStore.send(.newTemperatureReadingButtonTapped(child.id))
                            }
                        }
                    }

                    if !syncStore.conflicts.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(LocalizedStringResource("locSyncConflicts", defaultValue: "Sync conflicts", comment: "Button title in Timeline: Sync conflicts"), systemImage: "exclamationmark.triangle.fill") {
                                syncStore.send(.conflictListButtonTapped)
                            }
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
        .palette(palette)
    }
}

#if DEBUG
#Preview("Sleep tab") { ScreenFixtures.preview(.sleepTab) }
#Preview("Growth tab") { ScreenFixtures.preview(.growthTab) }
#Preview("Temperature tab") { ScreenFixtures.preview(.temperatureTab) }
#Preview("Growth entry sheet") { ScreenFixtures.preview(.growthEntrySheet) }
#endif
