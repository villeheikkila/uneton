import Dependencies
import Foundation
import SQLiteData
import Testing
import UnetonCore
@testable import Uneton

@MainActor
struct DemoRuntimeTests {
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
