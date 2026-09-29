import Dependencies
import Foundation
import SQLiteData
import Testing
import UnetonCore
@testable import Uneton

@MainActor
struct DemoRuntimeTests {
    @Test func `a retried Watch wake cannot end a later sleep`() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase(inMemory: true)
            $0.uuid = .incrementing
            $0.date.now = ModelFixtures.now
        } operation: {
            @Dependency(\.defaultDatabase) var database
            let session = SessionStore(demo: true)
            let demo = DemoRuntime(session: session)
            #expect(await demo.auth.developmentAuthenticate("Caregiver") == nil)
            #expect(await demo.family.createChildFamily("Aino", ModelFixtures.now, "none") == nil)
            let child = try #require(await database.read { try Child.fetchOne($0) })
            let earlierID = SleepSession.ID()
            let laterID = SleepSession.ID()
            try await database.write { db in
                try SleepSession.insert { ModelFixtures.sleep(id: earlierID, familyID: child.familyID,
                    childID: child.id, endedAt: ModelFixtures.now.addingTimeInterval(-1_800)) }.execute(db)
                try SleepSession.insert { ModelFixtures.sleep(id: laterID, familyID: child.familyID,
                    childID: child.id, startedAt: ModelFixtures.now.addingTimeInterval(-900),
                    endedAt: nil) }.execute(db)
            }

            let reply = await session.handleWatchRequest(WatchDiaryRequest(action: .endSleep,
                familyID: child.familyID, childID: child.id, sessionID: earlierID))
            #expect(reply.errorMessage == nil)
            #expect(reply.snapshot.selectedChild(id: child.id)?.activeSleepID == laterID)
            let later = try await database.read { try SleepSession.find(laterID).fetchOne($0) }
            #expect(later?.endedAt == nil)
            #expect(try await database.read { try PendingCommand.fetchCount($0) } == 0)

            let commandID = PendingCommand.ID(rawValue: earlierID.rawValue)
            try await database.write { db in
                try SleepSession.find(earlierID).delete().execute(db)
                try SleepSession.find(laterID).delete().execute(db)
                try AcknowledgedCommand.insert {
                    AcknowledgedCommand(id: commandID, familyID: child.familyID, kind: "startSleep",
                        payloadJSON: Data("{}".utf8), createdAt: ModelFixtures.now,
                        acknowledgedAt: ModelFixtures.now)
                }.execute(db)
            }
            let replay = await session.handleWatchRequest(WatchDiaryRequest(action: .startSleep,
                familyID: child.familyID, childID: child.id, sessionID: earlierID))
            #expect(replay.errorMessage == nil)
            #expect(replay.snapshot.selectedChild(id: child.id)?.activeSleepID == nil)
            #expect(try await database.read { try PendingCommand.fetchCount($0) } == 0)
        }
    }

    @Test func `demo clients drive an isolated diary without authentication or sync state`() async throws {
        try await withDependencies {
            try $0.bootstrapDatabase(inMemory: true)
            $0.uuid = .incrementing
            $0.date.now = Date(timeIntervalSince1970: 1_790_000_000)
        } operation: {
            @Dependency(\.defaultDatabase) var database
            let session = SessionStore(demo: true)
            let demo = DemoRuntime(session: session)

            #expect(!session.isAuthenticated)
            #expect(await demo.auth.developmentAuthenticate("Caregiver") == nil)
            #expect(session.isAuthenticated)

            let birthDate = Date(timeIntervalSince1970: 1_700_000_000)
            #expect(await demo.family.createChildFamily("Aino", birthDate, "none") == nil)
            let child = try #require(await database.read { try Child.fetchOne($0) })
            let family = try #require(await database.read { try Family.fetchOne($0) })
            #expect(child.familyID == family.id)

            #expect(await demo.diary.logTemperature(family.id, child.id, nil,
                birthDate, 3_720, "") == nil)
            let reading = try #require(await database.read { try TemperatureReading.fetchOne($0) })
            #expect(reading.centiCelsius == 3_720)
            #expect(try await database.read { try PendingCommand.fetchCount($0) } == 0)
            #expect(try await database.read { try AuthoritativeRecord.fetchCount($0) } == 0)

            let (signedOut, error) = await demo.sharing.signOut()
            #expect(signedOut && error == nil)
            #expect(!session.isAuthenticated)
            #expect(try await database.read { try Family.fetchCount($0) } == 0)
        }
    }
}
