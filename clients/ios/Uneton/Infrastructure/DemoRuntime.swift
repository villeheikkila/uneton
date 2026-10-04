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
    private var profileName = "Alex"
    private var familyName = String(localized: LocalizedStringResource("locOurFamily", defaultValue: "Our family", comment: "Message in DemoRuntime: Our family"))
    private var invitedCaregiverIsPresent = true
    private var currentRole = "owner"
    private var pendingInvites: [ManagedFamilyInvite] = []
    private let demoUserID = UserID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let caregiverID = UserID(uuidString: "22222222-2222-2222-2222-222222222222")!

    init(session: SessionStore) {
        self.session = session
    }

    var auth: SessionAuthClient {
        SessionAuthClient(
            completeAppleAuthorization: { _ in String(localized: LocalizedStringResource("locUseTheDemoSignInButtonToExploreWithoutAnAccount", defaultValue: "Use the demo sign in button to explore without an account.", comment: "Message in DemoRuntime: Use the demo sign in button to explore without an account.")) },
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
                    let family = Family(id: Family.ID(rawValue: uuid()), name: String(localized: LocalizedStringResource("locOurFamily", defaultValue: "Our family", comment: "Message in DemoRuntime: Our family")), role: "owner", updatedAt: now)
                    let child = Child(id: Child.ID(rawValue: uuid()), familyID: family.id, nickname: name,
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
                    return String(localized: LocalizedStringResource("locOnlyDemoInvitationsWorkInDemoMode", defaultValue: "Only demo invitations work in demo mode.", comment: "Message in DemoRuntime: Only demo invitations work in demo mode."))
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
                    let record = GrowthMeasurement(id: id ?? GrowthMeasurement.ID(rawValue: uuid()), familyID: familyID, childID: childID,
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
                    let record = TemperatureReading(id: id ?? TemperatureReading.ID(rawValue: uuid()), familyID: familyID, childID: childID,
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
                    let record = SleepSession(id: id ?? SleepSession.ID(rawValue: uuid()), familyID: familyID, childID: childID,
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
            deleteAccount: { [self] in (await clear(), nil) },
            setLiveActivitiesEnabled: { [self] in session.liveActivitiesEnabled = $0 },
            setNotificationsEnabled: { [self] in session.notificationsEnabled = $0 },
            setReminderLeadMinutes: { [self] in session.reminderLeadMinutes = $0 },
            signOut: { [self] in (await clear(), nil) }
        )
    }

    var management: SessionFamilyManagementClient {
        SessionFamilyManagementClient(
            load: { [self] familyID in
                let localFamily = try await database.read { db in try Family.find(familyID).fetchOne(db) }
                let role = localFamily?.role ?? currentRole
                var members = [ManagedFamilyMember(id: demoUserID, displayName: profileName,
                    role: role, joinedAt: now.addingTimeInterval(-86_400 * 90))]
                if invitedCaregiverIsPresent {
                    members.append(ManagedFamilyMember(id: caregiverID, displayName: "Sam",
                        role: role == "owner" ? "caregiver" : "owner",
                        joinedAt: now.addingTimeInterval(-86_400 * 30)))
                }
                return FamilyManagementSnapshot(familyID: familyID, familyName: localFamily?.name ?? familyName,
                    myUserID: demoUserID, myDisplayName: profileName, myRole: role,
                    members: members, pendingInvites: pendingInvites)
            },
            updateProfile: { [self] name in profileName = name },
            renameFamily: { [self] familyID, name in
                familyName = name
                try await database.write { db in
                    if var family = try Family.find(familyID).fetchOne(db) {
                        family.name = name
                        try Family.upsert { family }.execute(db)
                    }
                }
            },
            removeMember: { [self] _, _ in invitedCaregiverIsPresent = false },
            transferOwnership: { [self] familyID, _ in
                currentRole = "caregiver"
                try await database.write { db in
                    if var family = try Family.find(familyID).fetchOne(db) {
                        family.role = "caregiver"
                        try Family.upsert { family }.execute(db)
                    }
                }
            },
            revokeInvite: { [self] _, inviteID in pendingInvites.removeAll { $0.id == inviteID } },
            leaveFamily: { [self] familyID in
                try await database.write { db in try Family.find(familyID).delete().execute(db) }
            },
            deleteFamily: { [self] familyID in
                try await database.write { db in try Family.find(familyID).delete().execute(db) }
            },
            invite: { [self] _ in
                pendingInvites.append(ManagedFamilyInvite(id: FamilyInviteID(rawValue: uuid()),
                    expiresAt: now.addingTimeInterval(7 * 86_400), createdAt: now))
                return URL(string: "uneton://invite/demo")!
            },
            addChild: { [self] familyID, name, birthDate, reference in
                let child = Child(id: Child.ID(rawValue: uuid()), familyID: familyID, nickname: name,
                    birthDate: birthDate, growthReference: reference, revision: 1, updatedAt: now)
                try await database.write { db in try Child.insert { child }.execute(db) }
            },
            createFamily: { [self] familyID, name in
                let family = Family(id: familyID, name: name, role: "owner", updatedAt: now)
                try await database.write { db in try Family.insert { family }.execute(db) }
            },
            updateChild: { [self] child in
                var updated = child
                updated.revision += 1
                updated.updatedAt = now
                let saved = updated
                try await database.write { db in try Child.upsert { saved }.execute(db) }
            },
            deleteChild: { [self] child in
                try await database.write { db in try Child.find(child.id).delete().execute(db) }
            },
            importHuckleberry: { [self] child, history in
                let updatedAt = now
                return try await database.write { db in
                    var count = 0
                    for sleep in history.sleeps {
                        let id = sleep.sessionID(familyID: child.familyID, childID: child.id)
                        guard try SleepSession.find(id).fetchOne(db) == nil else { continue }
                        let record = SleepSession(id: id, familyID: child.familyID, childID: child.id,
                            startedAt: sleep.startedAt, endedAt: sleep.endedAt, revision: 1,
                            authorID: demoUserID, source: "history_import",
                            startCondition: sleep.startCondition, sleepLocation: sleep.sleepLocation,
                            endCondition: sleep.endCondition, updatedAt: updatedAt)
                        try SleepSession.insert { record }.execute(db)
                        count += 1
                    }
                    return count
                }
            }
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
            return String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated"))
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
    var errorDescription: String? { String(localized: LocalizedStringResource("locThisDemoEntryIsNoLongerAvailable", defaultValue: "This demo entry is no longer available.", comment: "Message in DemoRuntime: This demo entry is no longer available.")) }
}
#endif
