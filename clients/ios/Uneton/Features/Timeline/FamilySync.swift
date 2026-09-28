import ComposableArchitecture2
import Foundation
import UnetonCore

@Feature
struct FamilySync {
    struct State {
        let familyID: Family.ID
        var entry: SleepEntry.State?
        var errorMessage: String?
        var growthEntry: GrowthEntry.State?
        var temperatureEntry: TemperatureEntry.State?
        var isForeground = false
        var isPresentingConflicts = false
        var sharing: FamilySharing.State?
        @StoreTaskID var observation
        @StoreTaskID var refresh
        @StoreTaskID var reference
        @StoreTaskID var resolve
        @StoreTaskID var wake
    }

    enum Action {
        case endSleepButtonTapped(SleepSession.ID)
        case entry(SleepEntry.Action)
        case familyButtonTapped(Bool, Bool, Int)
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
        case sleepSelected(Child.ID, String, SleepSession.ID, Date, Date?)
    }

    @FeatureEnvironment(\.sessionSync) private var sessionSync
    @FeatureEnvironment(\.sessionDiary) private var sessionDiary

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
            case let .familyButtonTapped(notificationsEnabled, liveActivitiesEnabled, reminderLeadMinutes):
                state.sharing = FamilySharing.State(
                    familyID: state.familyID,
                    notificationsEnabled: notificationsEnabled,
                    liveActivitiesEnabled: liveActivitiesEnabled,
                    reminderLeadMinutes: reminderLeadMinutes
                )
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
                    readingID: readingID, measuredAt: measuredAt, centiCelsius: centiCelsius, note: note)
            case let .newTemperatureReadingButtonTapped(childID):
                state.temperatureEntry = TemperatureEntry.State(familyID: state.familyID, childID: childID)
            case let .growthMeasurementSelected(childID, measurementID, measuredAt, grams, millimeters, note):
                state.growthEntry = GrowthEntry.State(
                    familyID: state.familyID, childID: childID, measurementID: measurementID,
                    measuredAt: measuredAt, weightGrams: grams, heightMillimeters: millimeters, note: note
                )
            case let .growthReferenceChanged(childID, reference):
                let familyID = state.familyID
                state.errorMessage = nil
                store.addTask(id: state.reference) {
                    let error = await sessionDiary.setGrowthReference(familyID, childID, reference)
                    try store.modify { $0.errorMessage = error }
                }
            case let .newGrowthMeasurementButtonTapped(childID):
                state.growthEntry = GrowthEntry.State(familyID: state.familyID, childID: childID)
            case let .newSleepButtonTapped(childID, childName):
                state.entry = SleepEntry.State(
                    familyID: state.familyID,
                    childID: childID,
                    childName: childName
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
            case let .sleepSelected(childID, childName, sessionID, startedAt, endedAt):
                state.entry = SleepEntry.State(
                    familyID: state.familyID,
                    childID: childID,
                    childName: childName,
                    sessionID: sessionID,
                    startedAt: startedAt,
                    endedAt: endedAt
                )
            }
        }
        .ifLet(\.entry) { SleepEntry() }
        .ifLet(\.growthEntry) { GrowthEntry() }
        .ifLet(\.temperatureEntry) { TemperatureEntry() }
        .ifLet(\.sharing) { FamilySharing() }
        .onMount(id: store.isForeground ? store.familyID : nil) { state in
            guard state.isForeground else { return }
            let familyID = state.familyID
            store.addTask(id: state.observation) {
                await sessionSync.observe(familyID)
            }
        }
    }
}
