import ComposableArchitecture2
import SwiftUI
import UnetonCore

struct TimelineContent: View {
    typealias Mode = FamilySync.Tab

    @Environment(SessionStore.self) private var session
    @Bindable var syncStore: StoreOf<FamilySync>
    let child: Child

    var body: some View {
        TabView(selection: $syncStore.selectedTab) {
            ZStack {
                SkyBackground()
                SleepHome(
                    childName: child.nickname,
                    sessions: syncStore.sessions,
                    forecast: session.forecast?.childID == child.id ? session.forecast : nil,
                    isWaking: syncStore.wake.isRunning,
                    onStart: { syncStore.send(.newSleepButtonTapped(child.id, child.nickname)) },
                    onWake: { syncStore.send(.endSleepButtonTapped($0)) },
                    onSelectSession: { sleep in
                        syncStore.send(.sleepSelected(child.id, child.nickname, sleep.id, sleep.startedAt, sleep.endedAt))
                    }
                )
            }
            .tag(Mode.timeline)
            .tabItem {
                Label(Mode.timeline.title, systemImage: Mode.timeline.systemImage)
            }

            ZStack {
                SkyBackground()
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
                Label(Mode.growth.title, systemImage: Mode.growth.systemImage)
            }

            ZStack {
                SkyBackground()
                TemperatureContent(readings: syncStore.temperatureReadings,
                    onAdd: { syncStore.send(.newTemperatureReadingButtonTapped(child.id)) },
                    onSelect: { reading in
                        syncStore.send(.temperatureReadingSelected(child.id, reading.id,
                            reading.measuredAt, reading.centiCelsius, reading.note))
                    })
            }
            .tag(Mode.temperature)
            .tabItem { Label(Mode.temperature.title, systemImage: Mode.temperature.systemImage) }

            ZStack {
                SkyBackground()
                TrendsContent(sessions: syncStore.sessions, range: $syncStore.insightsRangeDays)
            }
            .tag(Mode.trends)
            .tabItem {
                Label(Mode.trends.title, systemImage: Mode.trends.systemImage)
            }
        }
    }
}
