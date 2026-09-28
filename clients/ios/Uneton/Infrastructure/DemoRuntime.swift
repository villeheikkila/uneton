#if DEBUG
import ComposableArchitecture2
import Dependencies
import Foundation
import SQLiteData
import UnetonCore

/// An ephemeral UI sandbox. It never creates commands, credentials, or network requests.
/// The live app continues to use SessionStore and SyncCoordinator unchanged.
@MainActor
final class DemoRuntime {
    @Dependency(\.defaultDatabase) private var database
    @Dependency(\.date.now) private var now
    @Dependency(\.uuid) private var uuid

    let session: SessionStore

    init(session: SessionStore) {
        self.session = session
    }

    var auth: SessionAuthClient {
        SessionAuthClient(
            completeAppleAuthorization: { _ in "Use the demo sign in button to explore without an account." },
            developmentAuthenticate: { [self] _ in
                session.demoAuthenticate()
                return nil
            }
        )
    }

    var family: SessionFamilyClient {
        SessionFamilyClient(
            createChildFamily: { [self] name, birthDate, reference in
                await result {
                    let family = Family(id: uuid(), name: "Our family", role: "owner", updatedAt: now)
                    let child = Child(id: uuid(), familyID: family.id, nickname: name,
                                      birthDate: birthDate, growthReference: reference,
                                      revision: 1, updatedAt: now)
                    try await database.write { db in
                        try Family.insert { family }.execute(db)
                        try Child.insert { child }.execute(db)
                    }
                }
            },
            handleInvitation: { [self] url in
                guard url.scheme == "uneton", url.host == "invite", url.lastPathComponent == "demo" else {
                    return "Only demo invitations work in demo mode."
                }
                return await family.createChildFamily("Aino", now.addingTimeInterval(-180 * 86_400), "none")
            }
        )
    }

    var diary: SessionDiaryClient {
        SessionDiaryClient(
            deleteGrowth: { [self] _, id in
                await result { try await database.write { db in
                    try GrowthMeasurement.find(id).delete().execute(db)
                } }
            },
            deleteTemperature: { [self] _, id in
                await result { try await database.write { db in
                    try TemperatureReading.find(id).delete().execute(db)
                } }
            },
            endSleep: { [self] _, id in
                await result {
                    guard var sleep = try await database.read({ try SleepSession.find(id).fetchOne($0) }) else {
                        throw DemoError.missingRecord
                    }
                    sleep.endedAt = max(now, sleep.startedAt.addingTimeInterval(60))
                    sleep.revision += 1
                    sleep.updatedAt = now
                    let updatedSleep = sleep
                    try await database.write { db in try SleepSession.upsert { updatedSleep }.execute(db) }
                }
            },
            logGrowth: { [self] familyID, childID, id, measuredAt, grams, millimeters, note in
                await result {
                    let revision = try await database.read { db in
                        try id.flatMap { try GrowthMeasurement.find($0).fetchOne(db) }?.revision ?? 0
                    }
                    let record = GrowthMeasurement(id: id ?? uuid(), familyID: familyID, childID: childID,
                        measuredAt: measuredAt, weightGrams: grams, heightMillimeters: millimeters,
                        note: note, revision: revision + 1, updatedAt: now)
                    try await database.write { db in try GrowthMeasurement.upsert { record }.execute(db) }
                }
            },
            logTemperature: { [self] familyID, childID, id, measuredAt, centiCelsius, note in
                await result {
                    let revision = try await database.read { db in
                        try id.flatMap { try TemperatureReading.find($0).fetchOne(db) }?.revision ?? 0
                    }
                    let record = TemperatureReading(id: id ?? uuid(), familyID: familyID, childID: childID,
                        measuredAt: measuredAt, centiCelsius: centiCelsius, note: note,
                        revision: revision + 1, updatedAt: now)
                    try await database.write { db in try TemperatureReading.upsert { record }.execute(db) }
                }
            },
            logSleep: { [self] familyID, childID, id, startedAt, endedAt in
                await result {
                    let revision = try await database.read { db in
                        try id.flatMap { try SleepSession.find($0).fetchOne(db) }?.revision ?? 0
                    }
                    let record = SleepSession(id: id ?? uuid(), familyID: familyID, childID: childID,
                        startedAt: startedAt, endedAt: endedAt, revision: revision + 1,
                        updatedAt: now)
                    try await database.write { db in try SleepSession.upsert { record }.execute(db) }
                }
            },
            resolveConflict: { _, _, _ in nil },
            setGrowthReference: { [self] _, childID, reference in
                await result {
                    guard var child = try await database.read({ try Child.find(childID).fetchOne($0) }) else {
                        throw DemoError.missingRecord
                    }
                    child.growthReference = reference
                    child.revision += 1
                    child.updatedAt = now
                    let updatedChild = child
                    try await database.write { db in try Child.upsert { updatedChild }.execute(db) }
                }
            },
            startSleep: { [self] familyID, childID, _, startedAt in
                await diary.logSleep(familyID, childID, nil, startedAt, nil)
            }
        )
    }

    var sharing: SessionSharingClient {
        SessionSharingClient(
            createInvite: { _ in (URL(string: "uneton://invite/demo"), nil) },
            deleteAccount: { [self] in (await clear(), nil) },
            setLiveActivitiesEnabled: { [self] in session.liveActivitiesEnabled = $0 },
            setNotificationsEnabled: { [self] in session.notificationsEnabled = $0 },
            setReminderLeadMinutes: { [self] in session.reminderLeadMinutes = $0 },
            signOut: { [self] in (await clear(), nil) }
        )
    }

    var sync: SessionSyncClient {
        SessionSyncClient(
            handleURL: { [self] url in _ = await family.handleInvitation(url) },
            isAuthenticated: { [self] in session.isAuthenticated },
            observe: { _ in
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(3_600)) }
            },
            refresh: { _ in },
            validateCredential: { }
        )
    }

    private func result(_ operation: () async throws -> Void) async -> String? {
        do {
            try await operation()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func clear() async -> Bool {
        do {
            try await database.write { db in
                try TemperatureReading.delete().execute(db)
                try GrowthMeasurement.delete().execute(db)
                try SleepSession.delete().execute(db)
                try Child.delete().execute(db)
                try Family.delete().execute(db)
            }
            session.demoSignOut()
            return true
        } catch {
            return false
        }
    }
}

private enum DemoError: LocalizedError {
    case missingRecord
    var errorDescription: String? { "This demo entry is no longer available." }
}
#endif
