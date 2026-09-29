import ComposableArchitecture2
import SwiftUI
import UnetonCore

struct TimelineContent: View {
    typealias Mode = FamilySync.Tab

    @Environment(SessionStore.self) private var session
    @Bindable var syncStore: StoreOf<FamilySync>
    let child: Child
    let navigationNamespace: Namespace.ID

    private var activeSession: SleepSession? { syncStore.activeSession }

    var body: some View {
        TabView(selection: $syncStore.selectedTab) {
            ZStack {
                SleepBackground()
                SleepTimelineContent(
                    childName: child.nickname,
                    sessions: syncStore.sessions,
                    forecast: session.forecast?.childID == child.id ? session.forecast : nil,
                    navigationNamespace: navigationNamespace,
                    onSelectSession: { sleep in
                        syncStore.send(.sleepSelected(child.id, child.nickname, sleep.id, sleep.startedAt, sleep.endedAt))
                    }
                )
            }
            .tag(Mode.timeline)
            .tabItem {
                Label(Mode.timeline.rawValue, systemImage: Mode.timeline.systemImage)
            }

            ZStack {
                SleepBackground()
                GrowthContent(
                    child: child,
                    measurements: syncStore.growthMeasurements,
                    referencePoints: syncStore.referencePoints,
                    onAdd: { syncStore.send(.newGrowthMeasurementButtonTapped(child.id)) },
                    onSelect: { measurement in
                        syncStore.send(.growthMeasurementSelected(
                            child.id, measurement.id, measurement.measuredAt,
                            measurement.weightGrams, measurement.heightMillimeters, measurement.note
                        ))
                    },
                    onReferenceChanged: { reference in
                        syncStore.send(.growthReferenceChanged(child.id, reference))
                    }
                )
            }
            .tag(Mode.growth)
            .tabItem {
                Label(Mode.growth.rawValue, systemImage: Mode.growth.systemImage)
            }

            ZStack {
                SleepBackground()
                TemperatureContent(readings: syncStore.temperatureReadings,
                    onAdd: { syncStore.send(.newTemperatureReadingButtonTapped(child.id)) },
                    onSelect: { reading in
                        syncStore.send(.temperatureReadingSelected(child.id, reading.id,
                            reading.measuredAt, reading.centiCelsius, reading.note))
                    })
            }
            .tag(Mode.temperature)
            .tabItem { Label(Mode.temperature.rawValue, systemImage: Mode.temperature.systemImage) }

            ZStack {
                SleepBackground()
                TrendsContent(sessions: syncStore.sessions, range: $syncStore.insightsRangeDays)
            }
            .tag(Mode.trends)
            .tabItem {
                Label(Mode.trends.rawValue, systemImage: Mode.trends.systemImage)
            }
        }
        .tabViewBottomAccessory(isEnabled: syncStore.selectedTab == .timeline) {
            HStack {
                Spacer(minLength: 44)
                bottomControl
                Spacer(minLength: 44)
            }
            .padding(.vertical, 8)
        }
        .tint(Color.sleepIndigo)
    }

    @ViewBuilder
    private var bottomControl: some View {
        if let activeSession {
            Button {
                syncStore.send(.endSleepButtonTapped(activeSession.id))
            } label: {
                Label("Wake \(child.nickname)", systemImage: "sun.max.fill")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.sleepDawn)
            .disabled(syncStore.wake.isRunning)
            .accessibilityHint("Ends the current sleep at the present time")
        } else {
            Button {
                syncStore.send(.newSleepButtonTapped(child.id, child.nickname))
            } label: {
                Label("Start sleep", systemImage: "moon.fill")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.sleepIndigo)
        }
    }
}
