import ComposableArchitecture2
import Foundation
import Observation
import SQLiteData
import UnetonCore

@Feature
struct FamilySync {
    enum Tab: String, CaseIterable, Identifiable {
        case timeline = "Sleep", trends = "Insights", growth = "Growth", temperature = "Temperature"
        var id: Self { self }
    }

    struct State {
        let familyID: Family.ID
        let childID: Child.ID?
        @ObservationIgnored @DebugSnapshotIgnored @FetchAll var sessions: [SleepSession]
        @ObservationIgnored @DebugSnapshotIgnored @FetchAll var growthMeasurements: [GrowthMeasurement]
        @ObservationIgnored @DebugSnapshotIgnored @FetchAll var temperatureReadings: [TemperatureReading]
        @ObservationIgnored @DebugSnapshotIgnored @FetchAll var referencePoints: [GrowthReferencePoint]
        @ObservationIgnored @DebugSnapshotIgnored @FetchAll var conflicts: [SyncConflict]
        var selectedTab: Tab = .timeline
        var insightsRangeDays = 7
        var entry: SleepEntry.State?
        var errorMessage: String?
        var growthEntry: GrowthEntry.State?
        var temperatureEntry: TemperatureEntry.State?
        var isForeground = false
        var isPresentingConflicts = false
        var management: FamilyManagement.State?
        var sharing: FamilySharing.State?
        @StoreTaskID var observation
        @StoreTaskID var refresh
        @StoreTaskID var reference
        @StoreTaskID var resolve
        @StoreTaskID var wake

        init(familyID: Family.ID, childID: Child.ID? = nil) {
            self.familyID = familyID
            self.childID = childID
            if let childID {
                _sessions = FetchAll(SleepSession.where {
                    $0.childID.eq(childID) && $0.deletedAt.is(nil) && $0.supersededByID.is(nil)
                }.order { $0.startedAt.desc() })
                _growthMeasurements = FetchAll(GrowthMeasurement.where {
                    $0.childID.eq(childID) && $0.deletedAt.is(nil)
                }.order { $0.measuredAt.desc() })
                _temperatureReadings = FetchAll(TemperatureReading.where {
                    $0.childID.eq(childID) && $0.deletedAt.is(nil)
                }.order { $0.measuredAt.desc() })
            } else {
                _sessions = FetchAll(SleepSession.none)
                _growthMeasurements = FetchAll(GrowthMeasurement.none)
                _temperatureReadings = FetchAll(TemperatureReading.none)
            }
            _referencePoints = FetchAll(GrowthReferencePoint.order { $0.ageMonths })
            _conflicts = FetchAll(SyncConflict.where { $0.familyID.eq(familyID) }
                .order { $0.createdAt.desc() })
        }

        var activeSession: SleepSession? { sessions.first { $0.endedAt == nil } }
    }

    enum Action {
        case endSleepButtonTapped(SleepSession.ID)
        case entry(SleepEntry.Action)
        case familyButtonTapped
        case foregroundChanged(Bool)
        case conflictListButtonTapped
        case growthEntry(GrowthEntry.Action)
        case temperatureEntry(TemperatureEntry.Action)
        case temperatureReadingSelected(Child.ID, TemperatureReading.ID, Date, Int, String)
        case newTemperatureReadingButtonTapped(Child.ID)
        case growthMeasurementSelected(Child.ID, GrowthMeasurement.ID, Date, Int?, Int?, String)
        case growthReferenceChanged(Child.ID, String)
        case newGrowthMeasurementButtonTapped(Child.ID)
        case newSleepButtonTapped(Child.ID, String)
        case refreshRequested
        case resolveConflictButtonTapped(SyncConflict.ID, SyncConflictResolution)
        case sharing(FamilySharing.Action)
        case management(FamilyManagement.Action)
        case sleepSelected(Child.ID, String, SleepSession.ID, Date, Date?)
    }

    @FeatureEnvironment(\.sessionSync) private var sessionSync
    @FeatureEnvironment(\.sessionDiary) private var sessionDiary
    @FeatureEnvironment(\.date.now) private var now

    var body: some Feature {
        Update { state, action in
            switch action {
            case let .endSleepButtonTapped(sessionID):
                let familyID = state.familyID
                state.errorMessage = nil
                store.addTask(id: state.wake) {
                    let error = await sessionDiary.endSleep(familyID, sessionID)
                    try store.modify { $0.errorMessage = error }
                }
            case .entry:
                break
            case .conflictListButtonTapped:
                state.isPresentingConflicts = true
            case .familyButtonTapped:
                state.management = FamilyManagement.State(familyID: state.familyID)
            case let .foregroundChanged(isForeground):
                state.isForeground = isForeground
                if !isForeground {
                    let observation = state.observation
                    store.addTask {
                        observation.cancel()
                    }
                }
            case .growthEntry:
                break
            case .temperatureEntry:
                break
            case let .temperatureReadingSelected(childID, readingID, measuredAt, centiCelsius, note):
                state.temperatureEntry = TemperatureEntry.State(familyID: state.familyID, childID: childID,
                    readingID: readingID, measuredAt: measuredAt, centiCelsius: centiCelsius, note: note, now: now)
            case let .newTemperatureReadingButtonTapped(childID):
                state.temperatureEntry = TemperatureEntry.State(familyID: state.familyID, childID: childID, now: now)
            case let .growthMeasurementSelected(childID, measurementID, measuredAt, grams, millimeters, note):
                state.growthEntry = GrowthEntry.State(
                    familyID: state.familyID, childID: childID, measurementID: measurementID,
                    measuredAt: measuredAt, weightGrams: grams, heightMillimeters: millimeters, note: note, now: now
                )
            case let .growthReferenceChanged(childID, reference):
                let familyID = state.familyID
                state.errorMessage = nil
                store.addTask(id: state.reference) {
                    let error = await sessionDiary.setGrowthReference(familyID, childID, reference)
                    try store.modify { $0.errorMessage = error }
                }
            case let .newGrowthMeasurementButtonTapped(childID):
                state.growthEntry = GrowthEntry.State(familyID: state.familyID, childID: childID, now: now)
            case let .newSleepButtonTapped(childID, childName):
                state.entry = SleepEntry.State(
                    familyID: state.familyID,
                    childID: childID,
                    childName: childName,
                    now: now
                )
            case .refreshRequested:
                let familyID = state.familyID
                store.addTask(id: state.refresh) {
                    await sessionSync.refresh(familyID)
                }
            case let .resolveConflictButtonTapped(conflictID, resolution):
                let familyID = state.familyID
                state.errorMessage = nil
                store.addTask(id: state.resolve) {
                    let error = await sessionDiary.resolveConflict(familyID, conflictID, resolution)
                    try store.modify { $0.errorMessage = error }
                }
            case .sharing:
                break
            case .management:
                break
            case let .sleepSelected(childID, childName, sessionID, startedAt, endedAt):
                state.entry = SleepEntry.State(
                    familyID: state.familyID,
                    childID: childID,
                    childName: childName,
                    sessionID: sessionID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    now: now
                )
            }
        }
        .ifLet(\.entry) { SleepEntry() }
        .ifLet(\.growthEntry) { GrowthEntry() }
        .ifLet(\.temperatureEntry) { TemperatureEntry() }
        .ifLet(\.sharing) { FamilySharing() }
        .ifLet(\.management) { FamilyManagement() }
        .onMount(id: store.isForeground ? store.familyID : nil) { state in
            guard state.isForeground else { return }
            let familyID = state.familyID
            store.addTask(id: state.observation) {
                await sessionSync.observe(familyID)
            }
        }
    }
}
