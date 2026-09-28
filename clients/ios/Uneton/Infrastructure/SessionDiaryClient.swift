import ComposableArchitecture2
import Foundation
import UnetonCore

struct SessionDiaryClient: Sendable {
    var deleteGrowth: @MainActor @Sendable (UUID, UUID) async -> String?
    var deleteTemperature: @MainActor @Sendable (UUID, UUID) async -> String?
    var endSleep: @MainActor @Sendable (UUID, UUID) async -> String?
    var logGrowth: @MainActor @Sendable (UUID, UUID, UUID?, Date, Int?, Int?, String) async -> String?
    var logTemperature: @MainActor @Sendable (UUID, UUID, UUID?, Date, Int, String) async -> String?
    var logSleep: @MainActor @Sendable (UUID, UUID, UUID?, Date, Date?) async -> String?
    var resolveConflict: @MainActor @Sendable (UUID, UUID, SyncConflictResolution) async -> String?
    var setGrowthReference: @MainActor @Sendable (UUID, UUID, String) async -> String?
    var startSleep: @MainActor @Sendable (UUID, UUID, String, Date) async -> String?

    @MainActor
    static func live(session: SessionStore) -> Self {
        Self(
            deleteGrowth: { familyID, measurementID in
                await session.deleteGrowthMeasurement(familyID: familyID, measurementID: measurementID)
                return session.errorMessage
            },
            deleteTemperature: { familyID, readingID in
                await session.deleteTemperatureReading(familyID: familyID, readingID: readingID)
                return session.errorMessage
            },
            endSleep: { familyID, sessionID in
                await session.endSleep(familyID: familyID, sessionID: sessionID)
                return session.errorMessage
            },
            logGrowth: { familyID, childID, measurementID, measuredAt, grams, millimeters, note in
                await session.logGrowthMeasurement(
                    familyID: familyID, childID: childID, measurementID: measurementID,
                    measuredAt: measuredAt, weightGrams: grams, heightMillimeters: millimeters, note: note
                )
                return session.errorMessage
            },
            logTemperature: { familyID, childID, readingID, measuredAt, centiCelsius, note in
                await session.logTemperatureReading(familyID: familyID, childID: childID,
                    readingID: readingID, measuredAt: measuredAt, centiCelsius: centiCelsius, note: note)
                return session.errorMessage
            },
            logSleep: { familyID, childID, sessionID, startedAt, endedAt in
                await session.logSleep(
                    familyID: familyID,
                    childID: childID,
                    sessionID: sessionID,
                    startedAt: startedAt,
                    endedAt: endedAt
                )
                return session.errorMessage
            },
            resolveConflict: { familyID, conflictID, resolution in
                await session.resolveConflict(conflictID, familyID: familyID, resolution: resolution)
                return session.errorMessage
            },
            setGrowthReference: { familyID, childID, reference in
                await session.setGrowthReference(familyID: familyID, childID: childID, growthReference: reference)
                return session.errorMessage
            },
            startSleep: { familyID, childID, childName, startedAt in
                await session.startSleep(
                    familyID: familyID,
                    childID: childID,
                    childName: childName,
                    startedAt: startedAt
                )
                return session.errorMessage
            }
        )
    }

    static let unimplemented = Self(
        deleteGrowth: { _, _ in fatalError("SessionDiaryClient.deleteGrowth is not configured") },
        deleteTemperature: { _, _ in fatalError("SessionDiaryClient.deleteTemperature is not configured") },
        endSleep: { _, _ in fatalError("SessionDiaryClient.endSleep is not configured") },
        logGrowth: { _, _, _, _, _, _, _ in fatalError("SessionDiaryClient.logGrowth is not configured") },
        logTemperature: { _, _, _, _, _, _ in fatalError("SessionDiaryClient.logTemperature is not configured") },
        logSleep: { _, _, _, _, _ in fatalError("SessionDiaryClient.logSleep is not configured") },
        resolveConflict: { _, _, _ in fatalError("SessionDiaryClient.resolveConflict is not configured") },
        setGrowthReference: { _, _, _ in fatalError("SessionDiaryClient.setGrowthReference is not configured") },
        startSleep: { _, _, _, _ in fatalError("SessionDiaryClient.startSleep is not configured") }
    )
}

nonisolated extension FeatureEnvironmentValues {
    @FeatureEnvironmentEntry(
        liveValue: SessionDiaryClient.unimplemented,
        previewValue: SessionDiaryClient.unimplemented
    )
    var sessionDiary = SessionDiaryClient.unimplemented
}
