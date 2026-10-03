import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import SQLiteData
import Testing
@testable import UnetonCore

@Suite(
  .serialized,
  .dependencies {
    $0.uuid = .incrementing
    $0.date.now = date(10_000)
    try $0.bootstrapDatabase()
  }
)
struct SyncCoordinatorTests {
  @Dependency(\.defaultDatabase) var database

  init() {
    Projection.verifiesIncrementalRefresh = true
  }

  @Test func watchStartUsesTheSessionIdentityRetainedAcrossRetries() async throws {
    let familyID = Family.ID()
    let childID = Child.ID()
    let sessionID = SleepSession.ID()
    let commandID = PendingCommand.ID(rawValue: sessionID.rawValue)
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    let coordinator = SyncCoordinator(deviceID: DeviceID(), accessToken: { "token" })
    let savedID = try await coordinator.startSleep(familyID: familyID, childID: childID,
      sessionID: sessionID, commandID: commandID, startedAt: date(1_000), source: "watch")
    let saved = try await database.read { try SleepSession.find(sessionID).fetchOne($0) }
    let pending = try await database.read { try PendingCommand.find(commandID).fetchOne($0) }
    #expect(savedID == sessionID)
    #expect(saved?.id == sessionID)
    #expect(saved?.source == "watch")
    #expect(pending?.kind == "startSleep")
  }

  @Test func childSettingsQueueOneDurableOptimisticUpdate() async throws {
    let familyID = Family.ID(rawValue: UUID(-201))
    let childID = Child.ID(rawValue: UUID(-202))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-203)), accessToken: { "token" })
    try await coordinator.updateChild(familyID: familyID, childID: childID,
      nickname: "New name", birthDate: date(1_000), predictionMode: "manual",
      manualIntervalMinutes: 150, quietHoursStartMinutes: 1_260,
      quietHoursEndMinutes: 420, timeZone: "Europe/Helsinki", growthReference: "girl")
    let state = try await database.read { db in
      (try Child.find(childID).fetchOne(db), try PendingCommand.fetchAll(db))
    }
    #expect(state.0?.nickname == "New name")
    #expect(state.0?.predictionMode == "manual")
    #expect(state.0?.manualIntervalMinutes == 150)
    #expect(state.0?.timeZone == "Europe/Helsinki")
    #expect(state.1.count == 1)
    #expect(state.1[0].kind == "updateChild")
    try await coordinator.updateChild(familyID: familyID, childID: childID,
      nickname: "Second name", birthDate: date(1_000), predictionMode: "manual",
      manualIntervalMinutes: 180, quietHoursStartMinutes: 1_260,
      quietHoursEndMinutes: 420, timeZone: "Europe/Helsinki", growthReference: "girl")
    let commands = try await database.read { db in
      try PendingCommand.where { $0.familyID.eq(familyID) }.fetchAll(db)
    }
    #expect(Set(commands.compactMap(\.expectedRevision)) == Set([1, 2]))
  }

  @Test func deletingChildHidesDiaryButKeepsTheCommandForSync() async throws {
    let familyID = Family.ID(rawValue: UUID(-211))
    let childID = Child.ID(rawValue: UUID(-212))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    let sleep = ModelFixtures.sleep(id: SleepSession.ID(rawValue: UUID(-213)),
      familyID: familyID, childID: childID)
    try await database.write { db in try SleepSession.insert { sleep }.execute(db) }
    let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-214)), accessToken: { "token" })
    try await coordinator.deleteChild(familyID: familyID, childID: childID)
    let state = try await database.read { db in
      (try Child.find(childID).fetchOne(db), try SleepSession.find(sleep.id).fetchOne(db),
        try PendingCommand.fetchAll(db))
    }
    #expect(state.0 == nil)
    #expect(state.1 == nil)
    #expect(state.2.count == 1)
    #expect(state.2[0].kind == "deleteChild")
  }

  @Test func snapshotChildTombstoneDoesNotResurrectTheBaby() async throws {
    let familyID = Family.ID(rawValue: UUID(-221))
    let childID = Child.ID(rawValue: UUID(-222))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    var tombstone = ServerChildPayload(id: childID, nickname: "Muru",
      birthDate: "2026-02-23", predictionMode: "adaptive",
      quietHoursStartMinutes: 1_200, quietHoursEndMinutes: 360,
      revision: 2, updatedAt: date(2_000))
    tombstone.deletedAt = date(2_000)
    let data = try JSONEncoder.uneton.encode(tombstone)
    try await database.write { db in
      try AuthoritativeRecord.upsert {
        AuthoritativeRecord(id: "child:\(childID.uuidString)", familyID: familyID,
          entityType: "child", entityID: EntityID(rawValue: childID.rawValue),
          revision: 2, operation: "upsert", payloadJSON: data)
      }.execute(db)
      try Projection.rebuild(familyID: familyID, database: db)
    }
    #expect(try await database.read { try Child.find(childID).fetchOne($0) } == nil)
  }

  @Test func acceptedChildDeletionRemovesThePendingCommandAndProjection() async throws {
    let familyID = Family.ID(rawValue: UUID(-231))
    let childID = Child.ID(rawValue: UUID(-232))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    var tombstone = ServerChildPayload(id: childID, nickname: "Muru",
      birthDate: "2026-02-23", predictionMode: "adaptive",
      quietHoursStartMinutes: 1_200, quietHoursEndMinutes: 360,
      revision: 2, updatedAt: date(2_000))
    tombstone.deletedAt = date(2_000)
    let deletedPayload = tombstone
    var api = APIClient.testValue
    api.sync = { _, _, request in
      let command = try #require(request.commands.first)
      let payload = try jsonValue(deletedPayload)
      return SyncResponse(
        commandResults: [APICommandResult(id: command.id, status: "accepted",
          entityID: EntityID(rawValue: childID.rawValue), payload: payload)],
        events: [SyncEvent(cursor: 1, entityType: "child",
          entityID: EntityID(rawValue: childID.rawValue), operation: "delete",
          revision: 2, payload: payload, createdAt: date(2_000))],
        nextCursor: 1, hasMore: false, serverTime: date(2_000))
    }
    try await withDependencies { $0.apiClient = api } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-233)), accessToken: { "token" })
      try await coordinator.deleteChild(familyID: familyID, childID: childID)
      _ = try await coordinator.synchronize(familyID: familyID)
    }
    let state = try await database.read { db in
      (try Child.find(childID).fetchOne(db), try PendingCommand.fetchCount(db))
    }
    #expect(state.0 == nil)
    #expect(state.1 == 0)
  }

  @Test func synchronizationReturnsTheServerForecast() async throws {
    let familyID = Family.ID(rawValue: UUID(-1))
    let childID = Child.ID(rawValue: UUID(-2))
    let activeSleepID = SleepSession.ID(rawValue: UUID(-3))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    let wake = SleepPrediction(
      targetAt: date(11_000), rangeStartAt: date(10_700), rangeEndAt: date(11_300),
      confidence: "medium", explanation: "Similar naps", algorithmVersion: 1,
      kind: "wake", sampleCount: 8
    )
    let nextSleep = SleepPrediction(
      targetAt: date(16_000), rangeStartAt: date(15_400), rangeEndAt: date(16_600),
      confidence: "medium", explanation: "Predicted from estimated wake", algorithmVersion: 1,
      kind: "sweet-spot", sampleCount: 8
    )
    let expected = SleepForecast(
      childID: childID, activeSleepID: activeSleepID, wakeEstimate: wake,
      nextSleepEstimate: nextSleep, nextSleepIsProvisional: true
    )
    var api = APIClient.testValue
    api.sync = { _, _, request in
      SyncResponse(
        commandResults: [], events: [], nextCursor: request.cursor, hasMore: false,
        serverTime: date(10_000), sleepForecast: expected
      )
    }

    let actual = try await withDependencies {
      $0.apiClient = api
    } operation: {
      try await SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
        .synchronize(familyID: familyID)
    }

    #expect(actual == expected)
  }

  @Test func authoritativeBaseReplaysPendingOverlay() async throws {
    let fixture = try await seedAuthoritativeSession(revision: 2, endedAt: date(3_600))
    let command = PendingCommand(
      id: PendingCommand.ID(rawValue: UUID(10)),
      familyID: fixture.familyID,
      kind: "upsertSleep",
      expectedRevision: 2,
      payloadJSON: try JSONEncoder.uneton.encode(
        SleepCommandPayload(
          id: fixture.sessionID,
          childID: fixture.childID,
          startedAt: date(300),
          endedAt: date(3_900),
          source: "manual"
        )
      ),
      createdAt: date(5_000)
    )
    try await database.write { database in
      try PendingCommand.insert { command }.execute(database)
      try Projection.rebuild(familyID: fixture.familyID, database: database)
    }

    let projected = try await database.read { try SleepSession.find(fixture.sessionID).fetchOne($0) }
    expectNoDifference(
      projected,
      ModelFixtures.sleep(
        id: fixture.sessionID,
        familyID: fixture.familyID,
        childID: fixture.childID,
        startedAt: date(300),
        endedAt: date(3_900),
        revision: 2,
        authorID: UserID(rawValue: UUID(-4)),
        source: "manual",
        updatedAt: date(5_000),
        pendingCommandID: PendingCommand.ID(rawValue: UUID(10))
      )
    )
  }

  @Test func staleSleepEditBecomesTerminalConflict() async throws {
    let fixture = try await seedAuthoritativeSession(revision: 3, endedAt: date(3_600))
    var api = APIClient.testValue
    api.sync = { _, _, request in
      let command = try #require(request.commands.first)
      return SyncResponse(
        commandResults: [
          APICommandResult(
            id: command.id,
            status: "rejected",
            error: "stale revision",
            entityID: EntityID(rawValue: fixture.sessionID.rawValue),
            payload: try jsonValue(serverSleep(fixture: fixture, revision: 3, endedAt: date(3_600)))
          )
        ],
        events: [],
        nextCursor: request.cursor,
        hasMore: false,
        serverTime: date(6_000)
      )
    }

    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      try await coordinator.upsertSleep(
        familyID: fixture.familyID,
        childID: fixture.childID,
        sessionID: fixture.sessionID,
        startedAt: date(600),
        endedAt: date(4_200)
      )
      _ = try await coordinator.synchronize(familyID: fixture.familyID)
    }

    let state = try await database.read { database in
      (
        try PendingCommand.fetchCount(database),
        try SyncConflict.fetchAll(database),
        try SleepSession.find(fixture.sessionID).fetchOne(database)
      )
    }
    #expect(state.0 == 0)
    #expect(state.1.count == 1)
    #expect(state.1[0].reason == "stale revision")
    #expect(state.2?.startedAt == date(0))
    #expect(state.2?.endedAt == date(3_600))
  }

  @Test func growthMeasurementReplaysPendingOverlay() async throws {
    let familyID = Family.ID(rawValue: UUID(-21))
    let childID = Child.ID(rawValue: UUID(-22))
    let measurementID = GrowthMeasurement.ID(rawValue: UUID(-23))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    let authoritative = ServerGrowthMeasurementPayload(
      id: measurementID, familyID: familyID, childID: childID, measuredAt: date(1_000),
      weightGrams: 6_100, heightMillimeters: 620, note: "Neuvola", revision: 2,
      updatedAt: date(1_000), deletedAt: nil
    )
    let pending = GrowthMeasurementCommandPayload(
      id: measurementID, childID: childID, measuredAt: date(2_000),
      weightGrams: 6_300, heightMillimeters: 630, note: "Home"
    )
    let authoritativeJSON = try JSONEncoder.uneton.encode(authoritative)
    let pendingJSON = try JSONEncoder.uneton.encode(pending)
    try await database.write { database in
      try AuthoritativeRecord.insert {
        AuthoritativeRecord(
          id: "growthMeasurement:\(measurementID)", familyID: familyID,
          entityType: "growthMeasurement", entityID: EntityID(rawValue: measurementID.rawValue), revision: 2,
          operation: "upsert", payloadJSON: authoritativeJSON
        )
      }.execute(database)
      try PendingCommand.insert {
        PendingCommand(
          id: PendingCommand.ID(rawValue: UUID(-24)), familyID: familyID, kind: "upsertGrowthMeasurement",
          expectedRevision: 2, payloadJSON: pendingJSON,
          createdAt: date(3_000)
        )
      }.execute(database)
      try Projection.rebuild(familyID: familyID, database: database)
    }

    let projected = try await database.read { try GrowthMeasurement.find(measurementID).fetchOne($0) }
    #expect(projected?.measuredAt == date(2_000))
    #expect(projected?.weightGrams == 6_300)
    #expect(projected?.heightMillimeters == 630)
    #expect(projected?.note == "Home")
    #expect(projected?.revision == 2)
    #expect(projected?.pendingCommandID == PendingCommand.ID(rawValue: UUID(-24)))
  }

  @Test func growthReferenceReplaysPendingChildUpdate() async throws {
    let familyID = Family.ID(rawValue: UUID(-61))
    let childID = Child.ID(rawValue: UUID(-62))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)

    try await SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-63)), accessToken: { "token" })
      .updateGrowthReference(familyID: familyID, childID: childID, growthReference: "girl")

    let child = try await database.read { database in try Child.find(childID).fetchOne(database) }
    #expect(child?.growthReference == "girl")
    let pending = try await database.read { database in
      try PendingCommand.where { $0.familyID.eq(familyID) }.fetchAll(database)
    }
    #expect(pending.count == 1)
    #expect(pending.first?.kind == "updateChild")
  }

  @Test func temperatureReadingReplaysPendingOverlay() async throws {
    let familyID = Family.ID(rawValue: UUID(-71))
    let childID = Child.ID(rawValue: UUID(-72))
    let readingID = TemperatureReading.ID(rawValue: UUID(-73))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    let authoritative = ServerTemperatureReadingPayload(id: readingID, familyID: familyID,
      childID: childID, measuredAt: date(1_000), centiCelsius: 3810,
      note: "Morning", revision: 2, updatedAt: date(1_000), deletedAt: nil)
    let pending = TemperatureReadingCommandPayload(id: readingID, childID: childID,
      measuredAt: date(2_000), centiCelsius: 3875, note: "Evening")
    let authoritativeJSON = try JSONEncoder.uneton.encode(authoritative)
    let pendingJSON = try JSONEncoder.uneton.encode(pending)
    try await database.write { database in
      try AuthoritativeRecord.insert {
        AuthoritativeRecord(id: "temperatureReading:\(readingID)", familyID: familyID,
          entityType: "temperatureReading", entityID: EntityID(rawValue: readingID.rawValue), revision: 2,
          operation: "upsert", payloadJSON: authoritativeJSON)
      }.execute(database)
      try PendingCommand.insert {
        PendingCommand(id: PendingCommand.ID(rawValue: UUID(-74)), familyID: familyID, kind: "upsertTemperatureReading",
          expectedRevision: 2, payloadJSON: pendingJSON, createdAt: date(3_000))
      }.execute(database)
      try Projection.rebuild(familyID: familyID, database: database)
    }
    let projected = try await database.read { try TemperatureReading.find(readingID).fetchOne($0) }
    #expect(projected?.centiCelsius == 3875)
    #expect(projected?.note == "Evening")
    #expect(projected?.revision == 2)
    #expect(projected?.pendingCommandID == PendingCommand.ID(rawValue: UUID(-74)))
  }

  @Test func temperatureEditsQueueSequentialRevisionsWhileOffline() async throws {
    let familyID = Family.ID(rawValue: UUID(-75))
    let childID = Child.ID(rawValue: UUID(-76))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-77)), accessToken: { "token" })
    try await coordinator.upsertTemperatureReading(familyID: familyID, childID: childID,
      measuredAt: date(1_000), centiCelsius: 3800)
    let reading = try #require(await database.read { try TemperatureReading.fetchAll($0).first })
    try await coordinator.upsertTemperatureReading(familyID: familyID, childID: childID,
      readingID: reading.id, measuredAt: date(2_000), centiCelsius: 3875)
    try await coordinator.deleteTemperatureReading(familyID: familyID, readingID: reading.id)
    let commands = try await database.read { try PendingCommand.fetchAll($0) }
      .filter { $0.familyID == familyID }
    #expect(commands.map(\.expectedRevision) == [nil, 1, 2])
    #expect(try await database.read { try TemperatureReading.find(reading.id).fetchOne($0) } == nil)
  }

  @Test func watchTemperatureEditKeepsTheRevisionTheUserSaw() async throws {
    let familyID = Family.ID(rawValue: UUID(-78))
    let childID = Child.ID(rawValue: UUID(-79))
    let readingID = TemperatureReading.ID(rawValue: UUID(-80))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    let authoritative = ServerTemperatureReadingPayload(id: readingID, familyID: familyID,
      childID: childID, measuredAt: date(1_000), centiCelsius: 3810,
      note: "Morning", revision: 3, updatedAt: date(1_000), deletedAt: nil)
    let authoritativeJSON = try JSONEncoder.uneton.encode(authoritative)
    try await database.write { database in
      try AuthoritativeRecord.insert {
        AuthoritativeRecord(id: "temperatureReading:\(readingID)", familyID: familyID,
          entityType: "temperatureReading", entityID: EntityID(rawValue: readingID.rawValue), revision: 3,
          operation: "upsert", payloadJSON: authoritativeJSON)
      }.execute(database)
      try Projection.rebuild(familyID: familyID, database: database)
    }
    try await SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-81)), accessToken: { "token" })
      .upsertTemperatureReading(familyID: familyID, childID: childID, readingID: readingID,
        measuredAt: date(2_000), centiCelsius: 3890, expectedRevision: 2)
    let pending = try await database.read { try PendingCommand.where { $0.familyID.eq(familyID) }.fetchOne($0) }
    #expect(pending?.expectedRevision == 2)
  }

  @Test func acceptedGrowthReferenceUpdatePersistsServerValue() async throws {
    let familyID = Family.ID(rawValue: UUID(-67))
    let childID = Child.ID(rawValue: UUID(-68))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    var api = APIClient.testValue
    api.sync = { _, _, request in
      let command = try #require(request.commands.first)
      let input = try JSONDecoder.uneton.decode(ChildCommandPayload.self, from: try JSONEncoder.uneton.encode(command.payload))
      #expect(input.growthReference == "boy")
      let child = ServerChildPayload(
        id: childID,
        nickname: "Muru",
        birthDate: "2026-02-23",
        predictionMode: "adaptive",
        quietHoursStartMinutes: 1_200,
        quietHoursEndMinutes: 360,
        growthReference: "boy",
        revision: 2,
        updatedAt: date(1)
      )
      return SyncResponse(
        commandResults: [
          APICommandResult(
            id: command.id,
            status: "accepted",
            entityID: EntityID(rawValue: childID.rawValue),
            payload: try jsonValue(child)
          )
        ],
        events: [],
        nextCursor: request.cursor,
        hasMore: false,
        serverTime: date(1)
      )
    }

    try await withDependencies { $0.apiClient = api } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-69)), accessToken: { "token" })
      try await coordinator.updateGrowthReference(
        familyID: familyID,
        childID: childID,
        growthReference: "boy"
      )
      _ = try await coordinator.synchronize(familyID: familyID)
    }

    let child = try await database.read { database in try Child.find(childID).fetchOne(database) }
    #expect(child?.growthReference == "boy")
    #expect(child?.revision == 2)
  }

  @Test func growthReferenceBootstrapIsCachedOffline() async throws {
    let familyID = Family.ID(rawValue: UUID(-64))
    let childID = Child.ID(rawValue: UUID(-65))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    var api = APIClient.testValue
    api.sync = { _, _, request in
      SyncResponse(
        commandResults: [], events: [], nextCursor: request.cursor, hasMore: false,
        serverTime: date(0),
        growthReferencePoints: [
          GrowthReferenceBootstrapPoint(reference: "girl", metric: "height", ageMonths: 6, sd: 0, value: 676)
        ]
      )
    }
    try await withDependencies { $0.apiClient = api } operation: {
      _ = try await SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-66)), accessToken: { "token" }).synchronize(familyID: familyID)
    }
    let point = try await database.read { database in
      try GrowthReferencePoint.find(GrowthReferencePoint.ID(rawValue: "girl:height:6:0")).fetchOne(database)
    }
    #expect(point?.value == 676)
  }

  @Test func duplicateStartRemapsToCanonicalServerSession() async throws {
    let familyID = Family.ID(rawValue: UUID(-1))
    let childID = Child.ID(rawValue: UUID(-2))
    let canonicalID = SleepSession.ID(rawValue: UUID(-3))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    var optimisticID: SleepSession.ID?
    var api = APIClient.testValue
    api.sync = { _, _, request in
      let command = try #require(request.commands.first)
      return SyncResponse(
        commandResults: [
          APICommandResult(
            id: command.id,
            status: "accepted",
            entityID: EntityID(rawValue: canonicalID.rawValue),
            payload: try jsonValue(
              ServerSleepPayload(
                id: canonicalID,
                familyID: familyID,
                childID: childID,
                startedAt: date(1_000),
                endedAt: nil,
                revision: 1,
                authorID: UserID(rawValue: UUID(-4)),
                source: "phone",
                updatedAt: date(1_000)
              )
            )
          )
        ],
        events: [],
        nextCursor: 0,
        hasMore: false,
        serverTime: date(1_001)
      )
    }

    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      optimisticID = try await coordinator.startSleep(
        familyID: familyID,
        childID: childID,
        startedAt: date(1_100)
      )
      _ = try await coordinator.synchronize(familyID: familyID)
    }

    let sessions = try await database.read { try SleepSession.fetchAll($0) }
    #expect(sessions.count == 1)
    #expect(sessions[0].id == canonicalID)
    #expect(sessions[0].pendingCommandID == nil)
    #expect(sessions.contains(where: { $0.id == optimisticID }) == false)
  }

  @Test func keepMineRequeuesAgainstCurrentServerRevision() async throws {
    let fixture = try await seedAuthoritativeSession(revision: 4, endedAt: date(3_600))
    let localPayload = try JSONEncoder.uneton.encode(
      SleepCommandPayload(
        id: fixture.sessionID,
        childID: fixture.childID,
        startedAt: date(600),
        endedAt: date(4_200),
        source: "manual"
      )
    )
    let serverPayload = try JSONEncoder.uneton.encode(serverSleep(fixture: fixture, revision: 4, endedAt: date(3_600)))
    let conflict = ModelFixtures.conflict(
      localPayloadJSON: localPayload, serverPayloadJSON: serverPayload,
      id: SyncConflict.ID(rawValue: UUID(-20)), familyID: fixture.familyID, entityID: EntityID(rawValue: fixture.sessionID.rawValue),
      expectedRevision: 3, createdAt: date(5_000)
    )
    try await database.write { try SyncConflict.insert { conflict }.execute($0) }

    let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
    try await coordinator.resolveConflict(conflict.id, resolution: .keepMine)

    let state = try await database.read { database in
      (
        try SyncConflict.fetchCount(database),
        try PendingCommand.fetchAll(database),
        try SleepSession.find(fixture.sessionID).fetchOne(database)
      )
    }
    #expect(state.0 == 0)
    #expect(state.1.count == 1)
    #expect(state.1[0].expectedRevision == 4)
    #expect(state.2?.startedAt == date(600))
    #expect(state.2?.endedAt == date(4_200))
  }

  @Test func automaticEndRebaseRunsOnceThenBecomesConflict() async throws {
    let fixture = try await seedAuthoritativeSession(revision: 3, endedAt: date(3_600))
    let responder = CollisionResponder(fixture: fixture)
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }

    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      try await coordinator.endSleep(
        familyID: fixture.familyID,
        sessionID: fixture.sessionID,
        endedAt: date(3_000)
      )
      _ = try await coordinator.synchronize(familyID: fixture.familyID)
    }

    let requestCount = await responder.requestCount
    #expect(requestCount == 2)
    let state = try await database.read { database in
      (
        try PendingCommand.fetchCount(database),
        try SyncConflict.fetchAll(database),
        try SleepSession.find(fixture.sessionID).fetchOne(database)
      )
    }
    #expect(state.0 == 0)
    #expect(state.1.count == 1)
    #expect(state.1[0].commandKind == "upsertSleep")
    #expect(state.2?.endedAt == date(3_500))
  }

  @Test func endInTheSameBatchFollowsTheCanonicalActiveSleep() async throws {
    let familyID = Family.ID(rawValue: UUID(-301))
    let childID = Child.ID(rawValue: UUID(-302))
    let localID = SleepSession.ID(rawValue: UUID(-303))
    let canonical = Fixture(familyID: familyID, childID: childID, sessionID: SleepSession.ID(rawValue: UUID(-304)))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    let responder = ScriptedResponder { index, request in
      switch index {
      case 1:
        expectNoDifference(request.commands.map(\.kind), ["startSleep", "endSleep"])
        let active = try jsonValue(serverSleep(fixture: canonical, revision: 3, endedAt: nil))
        return SyncResponse(
          commandResults: [
            APICommandResult(id: request.commands[0].id, status: "accepted",
              entityID: EntityID(rawValue: canonical.sessionID.rawValue), payload: active),
            APICommandResult(id: request.commands[1].id, status: "rejected", error: "active sleep not found"),
          ],
          events: [SyncEvent(cursor: 1, entityType: "sleepSession",
            entityID: EntityID(rawValue: canonical.sessionID.rawValue), operation: "upsert",
            revision: 3, payload: active, createdAt: date(2_000))],
          nextCursor: 1, hasMore: false, serverTime: date(2_000))
      default:
        return try endResponse(request, fixture: canonical, cursor: 2, revision: 4)
      }
    }
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }
    try await withDependencies { $0.apiClient = api } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-305)), accessToken: { "token" })
      try await coordinator.startSleep(familyID: familyID, childID: childID, sessionID: localID, startedAt: date(1_000))
      try await coordinator.endSleep(familyID: familyID, sessionID: localID, endedAt: date(3_600))
      _ = try await coordinator.synchronize(familyID: familyID)
    }
    let requests = await responder.requests
    #expect(requests.count == 2)
    let retried = try #require(requests.last?.commands.first)
    #expect(retried.kind == "endSleep")
    #expect(retried.expectedRevision == 3)
    #expect(try sleepCommandPayload(retried).id == canonical.sessionID)
    let state = try await database.read { db in
      (try SleepSession.find(localID).fetchOne(db), try SleepSession.find(canonical.sessionID).fetchOne(db),
        try PendingCommand.fetchCount(db), try SyncConflict.fetchCount(db))
    }
    #expect(state.0 == nil)
    #expect(state.1?.endedAt == date(3_600))
    #expect(state.2 == 0)
    #expect(state.3 == 0)
  }

  @Test func queuedEndIsRedirectedWhenStartMapsToAnotherActiveSleep() async throws {
    let familyID = Family.ID(rawValue: UUID(-311))
    let childID = Child.ID(rawValue: UUID(-312))
    let localID = SleepSession.ID(rawValue: UUID(-313))
    let canonical = Fixture(familyID: familyID, childID: childID, sessionID: SleepSession.ID(rawValue: UUID(-314)))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    @Dependency(\.defaultDatabase) var database
    let queuedEnd = PendingCommand(
      id: PendingCommand.ID(rawValue: UUID(-315)), familyID: familyID, kind: "endSleep", expectedRevision: 1,
      payloadJSON: try JSONEncoder.uneton.encode(SleepCommandPayload(id: localID, childID: childID,
        startedAt: date(1_000), endedAt: date(3_600), source: "phone")),
      createdAt: date(1_500), sequence: 1_000)
    let responder = ScriptedResponder { index, request in
      switch index {
      case 1:
        expectNoDifference(request.commands.map(\.kind), ["startSleep"])
        // The caregiver ends the sleep while the start is still in flight.
        try await database.write { db in try PendingCommand.insert { queuedEnd }.execute(db) }
        let active = try jsonValue(serverSleep(fixture: canonical, revision: 3, endedAt: nil))
        return SyncResponse(
          commandResults: [APICommandResult(id: request.commands[0].id, status: "accepted",
            entityID: EntityID(rawValue: canonical.sessionID.rawValue), payload: active)],
          events: [SyncEvent(cursor: 1, entityType: "sleepSession",
            entityID: EntityID(rawValue: canonical.sessionID.rawValue), operation: "upsert",
            revision: 3, payload: active, createdAt: date(2_000))],
          nextCursor: 1, hasMore: false, serverTime: date(2_000))
      default:
        return try endResponse(request, fixture: canonical, cursor: 2, revision: 4)
      }
    }
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }
    try await withDependencies { $0.apiClient = api } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-316)), accessToken: { "token" })
      try await coordinator.startSleep(familyID: familyID, childID: childID, sessionID: localID, startedAt: date(1_000))
      _ = try await coordinator.synchronize(familyID: familyID)
    }
    let requests = await responder.requests
    let redirected = try #require(requests.last?.commands.first)
    #expect(redirected.id == queuedEnd.id)
    #expect(redirected.expectedRevision == 3)
    #expect(try sleepCommandPayload(redirected).id == canonical.sessionID)
    let state = try await database.read { db in
      (try SleepSession.find(localID).fetchOne(db), try SleepSession.find(canonical.sessionID).fetchOne(db),
        try SyncConflict.fetchCount(db))
    }
    #expect(state.0 == nil)
    #expect(state.1?.endedAt == date(3_600))
    #expect(state.2 == 0)
  }

  @Test func staleEndOfAStillActiveSleepRebasesInsteadOfConflicting() async throws {
    let fixture = try await seedAuthoritativeSession(revision: 3, endedAt: nil)
    let responder = ScriptedResponder { index, request in
      switch index {
      case 1:
        let command = try #require(request.commands.first)
        #expect(command.expectedRevision == 3)
        let edited = try jsonValue(serverSleep(fixture: fixture, revision: 4, endedAt: nil))
        return SyncResponse(
          commandResults: [APICommandResult(id: command.id, status: "rejected", error: "stale revision",
            entityID: EntityID(rawValue: fixture.sessionID.rawValue), payload: edited)],
          events: [SyncEvent(cursor: 1, entityType: "sleepSession",
            entityID: EntityID(rawValue: fixture.sessionID.rawValue), operation: "upsert",
            revision: 4, payload: edited, createdAt: date(2_000))],
          nextCursor: 1, hasMore: false, serverTime: date(2_000))
      default:
        return try endResponse(request, fixture: fixture, cursor: 2, revision: 5)
      }
    }
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }
    try await withDependencies { $0.apiClient = api } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      try await coordinator.endSleep(familyID: fixture.familyID, sessionID: fixture.sessionID, endedAt: date(3_600))
      _ = try await coordinator.synchronize(familyID: fixture.familyID)
    }
    let retried = try #require(await responder.requests.last?.commands.first)
    #expect(retried.kind == "endSleep")
    #expect(retried.expectedRevision == 4)
    let state = try await database.read { db in
      (try SyncConflict.fetchCount(db), try SleepSession.find(fixture.sessionID).fetchOne(db))
    }
    #expect(state.0 == 0)
    #expect(state.1?.endedAt == date(3_600))
  }

  @Test func concurrentEditsReserveDistinctRevisions() async throws {
    let familyID = Family.ID(rawValue: UUID(-321))
    let childID = Child.ID(rawValue: UUID(-322))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-323)), accessToken: { "token" })
    try await withThrowingTaskGroup(of: Void.self) { group in
      for minutes in [120, 150, 180, 210] {
        group.addTask {
          try await coordinator.updateChild(familyID: familyID, childID: childID,
            nickname: "Muru", birthDate: date(1_000), predictionMode: "manual",
            manualIntervalMinutes: minutes, quietHoursStartMinutes: 1_200,
            quietHoursEndMinutes: 360, timeZone: "Europe/Helsinki", growthReference: "none")
        }
      }
      try await group.waitForAll()
    }
    let commands = try await database.read { db in
      try PendingCommand.where { $0.familyID.eq(familyID) }.order(by: \.sequence).fetchAll(db)
    }
    expectNoDifference(commands.map(\.expectedRevision), [1, 2, 3, 4])
  }

  @Test func paginationAppliesEveryPageAndAdvancesCursor() async throws {
    let fixture = Fixture(familyID: Family.ID(rawValue: UUID(-1)), childID: Child.ID(rawValue: UUID(-2)), sessionID: SleepSession.ID(rawValue: UUID(-3)))
    try await seedFamilyAndChild(familyID: fixture.familyID, childID: fixture.childID)
    let responder = PaginationResponder(fixture: fixture)
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }

    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      _ = try await coordinator.synchronize(familyID: fixture.familyID)
      #expect(try await coordinator.cursor(familyID: fixture.familyID) == 2)
    }

    #expect(await responder.requestCount == 2)
    #expect(await responder.commandCounts == [0, 0])
    let session = try await database.read { try SleepSession.find(fixture.sessionID).fetchOne($0) }
    #expect(session?.revision == 2)
    #expect(session?.endedAt == date(3_600))
  }

  @Test func concurrentSynchronizationUsesOneInFlightRequest() async throws {
    let familyID = Family.ID(rawValue: UUID(-1))
    let childID = Child.ID(rawValue: UUID(-2))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    let responder = SlowResponder()
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }

    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      async let first = coordinator.synchronize(familyID: familyID)
      async let second = coordinator.synchronize(familyID: familyID)
      _ = try await (first, second)
    }

    #expect(await responder.requestCount == 1)
  }

  @Test func commandQueuedDuringInFlightSyncIsDrainedBeforeSuccess() async throws {
    let fixture = Fixture(familyID: Family.ID(rawValue: UUID(-1)), childID: Child.ID(rawValue: UUID(-2)), sessionID: SleepSession.ID(rawValue: UUID(-3)))
    try await seedFamilyAndChild(familyID: fixture.familyID, childID: fixture.childID)
    let responder = PausedResponder(fixture: fixture)
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }

    try await withDependencies { $0.apiClient = api } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      let first = Task { try await coordinator.synchronize(familyID: fixture.familyID) }
      await responder.waitUntilStarted()
      _ = try await coordinator.startSleep(familyID: fixture.familyID, childID: fixture.childID, startedAt: date(1_000))
      let joined = Task { try await coordinator.synchronize(familyID: fixture.familyID) }
      await responder.release()
      _ = try await first.value
      _ = try await joined.value
    }

    #expect(await responder.commandCounts == [0, 1])
    #expect(try await database.read { try PendingCommand.fetchCount($0) } == 0)
  }

  @Test func malformedCursorResponseLeavesDurableCommandUntouched() async throws {
    let familyID = Family.ID(rawValue: UUID(-1))
    let childID = Child.ID(rawValue: UUID(-2))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    var api = APIClient.testValue
    api.sync = { _, _, request in
      SyncResponse(
        commandResults: request.commands.map {
          APICommandResult(id: $0.id, status: "accepted", entityID: nil, payload: nil)
        },
        events: [],
        nextCursor: request.cursor - 1,
        hasMore: false,
        serverTime: date(6_000)
      )
    }

    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      _ = try await coordinator.startSleep(familyID: familyID, childID: childID, startedAt: date(1_000))
      do {
        _ = try await coordinator.synchronize(familyID: familyID)
        Issue.record("Expected the regressing cursor to be rejected")
      } catch {
        #expect(error as? SyncError == .invalidServerPayload)
      }
    }

    let state = try await database.read { database in
      (try PendingCommand.fetchCount(database), try SyncState.find(familyID).fetchOne(database)?.cursor)
    }
    #expect(state.0 == 1)
    #expect(state.1 == nil)
  }

  @Test func skippedEventCursorLeavesDurableCommandUntouched() async throws {
    let familyID = Family.ID(rawValue: UUID(-1))
    let childID = Child.ID(rawValue: UUID(-2))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    var api = APIClient.testValue
    api.sync = { _, _, request in
      SyncResponse(
        commandResults: request.commands.map {
          APICommandResult(id: $0.id, status: "accepted", entityID: nil, payload: nil)
        },
        events: [], nextCursor: request.cursor + 1, hasMore: false, serverTime: date(6_000)
      )
    }

    try await withDependencies { $0.apiClient = api } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      _ = try await coordinator.startSleep(familyID: familyID, childID: childID, startedAt: date(1_000))
      do {
        _ = try await coordinator.synchronize(familyID: familyID)
        Issue.record("Expected an unexplained cursor advance to be rejected")
      } catch {
        #expect(error as? SyncError == .invalidServerPayload)
      }
    }

    let state = try await database.read { database in
      (try PendingCommand.fetchCount(database), try SyncState.find(familyID).fetchOne(database)?.cursor)
    }
    #expect(state.0 == 1)
    #expect(state.1 == nil)
  }

  @Test func foreignFamilyEventCannotAdvanceTheCursor() async throws {
    let fixture = Fixture(familyID: Family.ID(rawValue: UUID(-1)), childID: Child.ID(rawValue: UUID(-2)), sessionID: SleepSession.ID(rawValue: UUID(-3)))
    try await seedFamilyAndChild(familyID: fixture.familyID, childID: fixture.childID)
    var foreign = serverSleep(fixture: fixture, revision: 1, endedAt: nil)
    foreign.familyID = Family.ID(rawValue: UUID(-99))
    let foreignPayload = try jsonValue(foreign)
    var api = APIClient.testValue
    api.sync = { _, _, _ in
      SyncResponse(
        commandResults: [],
        events: [SyncEvent(
          cursor: 1, entityType: "sleepSession", entityID: EntityID(rawValue: fixture.sessionID.rawValue),
          operation: "upsert", revision: 1, payload: foreignPayload,
          createdAt: date(6_000)
        )],
        nextCursor: 1, hasMore: false, serverTime: date(6_000)
      )
    }

    await withDependencies { $0.apiClient = api } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      do {
        _ = try await coordinator.synchronize(familyID: fixture.familyID)
        Issue.record("Expected a foreign family event to be rejected")
      } catch {
        #expect(error as? SyncError == .invalidServerPayload)
      }
    }

    #expect(try await database.read { try SyncState.find(fixture.familyID).fetchOne($0)?.cursor } == nil)
  }

  @Test func networkFailureKeepsOptimisticStateAndCommandForRetry() async throws {
    let familyID = Family.ID(rawValue: UUID(-1))
    let childID = Child.ID(rawValue: UUID(-2))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    var api = APIClient.testValue
    api.sync = { _, _, _ in throw TestTransportError.offline }

    var optimisticID: SleepSession.ID?
    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      optimisticID = try await coordinator.startSleep(familyID: familyID, childID: childID, startedAt: date(1_000))
      do {
        _ = try await coordinator.synchronize(familyID: familyID)
        Issue.record("Expected the offline request to fail")
      } catch {
        #expect(error as? TestTransportError == .offline)
      }
    }

    let sessionID = try #require(optimisticID)
    let state = try await database.read { database in
      (try PendingCommand.fetchCount(database), try SleepSession.find(sessionID).fetchOne(database))
    }
    #expect(state.0 == 1)
    #expect(state.1?.endedAt == nil)
    #expect(state.1?.pendingCommandID != nil)
  }

  @Test func offlineBacklogIsSentInBoundedBatches() async throws {
    let familyID = Family.ID(rawValue: UUID(-1))
    try await database.write { database in
      try Family.insert { ModelFixtures.family(id: familyID, name: "Home", updatedAt: date(0)) }.execute(database)
      for index in 0..<101 {
        let childID = Child.ID(rawValue: UUID(index + 1_000))
        let payload = ChildCommandPayload(
          id: childID,
          nickname: "Child \(index)",
          birthDate: "2026-02-23",
          predictionMode: "adaptive",
          manualIntervalMinutes: nil,
          quietHoursStartMinutes: 1_200,
          quietHoursEndMinutes: 360
        )
        let payloadJSON = try JSONEncoder.uneton.encode(payload)
        try PendingCommand.insert {
          PendingCommand(
            id: PendingCommand.ID(rawValue: UUID(index + 2_000)),
            familyID: familyID,
            kind: "createChild",
            payloadJSON: payloadJSON,
            createdAt: date(Double(index)), sequence: Int64(index + 1)
          )
        }.execute(database)
      }
    }
    let responder = BatchResponder()
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }

    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      _ = try await coordinator.synchronize(familyID: familyID)
    }

    #expect(await responder.batchSizes == [100, 1])
    #expect(try await database.read { try PendingCommand.fetchCount($0) } == 0)
  }

  @Test func snapshotRecoveryReplaysAcknowledgedCommandsAfterServerRollback() async throws {
    let fixture = Fixture(familyID: Family.ID(rawValue: UUID(-1)), childID: Child.ID(rawValue: UUID(-2)), sessionID: SleepSession.ID(rawValue: UUID(-3)))
    try await seedFamilyAndChild(familyID: fixture.familyID, childID: fixture.childID)
    let responder = SnapshotRecoveryResponder(fixture: fixture)
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }

    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      _ = try await coordinator.startSleep(
        familyID: fixture.familyID,
        childID: fixture.childID,
        startedAt: date(1_000)
      )
      _ = try await coordinator.synchronize(familyID: fixture.familyID)
      _ = try await coordinator.synchronize(familyID: fixture.familyID)
      #expect(try await coordinator.generation(familyID: fixture.familyID) == "generation-after-restore")
    }

    let state = try await database.read { database in
      (
        try PendingCommand.fetchCount(database),
        try AcknowledgedCommand.fetchCount(database),
        try SleepSession.find(fixture.sessionID).fetchOne(database)
      )
    }
    #expect(state.0 == 0)
    #expect(state.1 == 1)
    #expect(state.2?.revision == 1)
    #expect(await responder.commandCounts == [1, 0, 1])
  }

  @Test func endForASessionTheServerLacksWaitsForAnotherDevicesReplay() async throws {
    let fixture = try await seedAuthoritativeSession(revision: 1, endedAt: nil)
    let sessionEntity = EntityID(rawValue: fixture.sessionID.rawValue)
    let rejectedID = LockIsolated<PendingCommand.ID?>(nil)
    let responder = ScriptedResponder { index, request in
      switch index {
      case 1:
        // Restored database: the start another phone made has not been replayed yet.
        let command = try #require(request.commands.first)
        rejectedID.setValue(command.id)
        return SyncResponse(commandResults: [APICommandResult(id: command.id, status: "rejected", error: "active sleep not found")],
          events: [], nextCursor: request.cursor, hasMore: false, serverTime: date(20_000))
      case 2:
        expectNoDifference(request.commands.count, 0)
        let active = try jsonValue(serverSleep(fixture: fixture, revision: 1, endedAt: nil))
        return SyncResponse(commandResults: [],
          events: [SyncEvent(cursor: request.cursor + 1, entityType: "sleepSession", entityID: sessionEntity,
            operation: "upsert", revision: 1, payload: active, createdAt: date(20_100))],
          nextCursor: request.cursor + 1, hasMore: false, serverTime: date(20_100))
      default:
        let command = try #require(request.commands.first)
        expectNoDifference(command.kind, "endSleep")
        // The server stored the first rejection under the original command ID.
        #expect(command.id != rejectedID.value)
        let ended = try jsonValue(serverSleep(fixture: fixture, revision: 2, endedAt: date(3_600)))
        return SyncResponse(commandResults: [APICommandResult(id: command.id, status: "accepted", entityID: sessionEntity, payload: ended)],
          events: [], nextCursor: request.cursor, hasMore: false, serverTime: date(20_200))
      }
    }
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }
    try await withDependencies { $0.apiClient = api } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      try await coordinator.endSleep(familyID: fixture.familyID, sessionID: fixture.sessionID, endedAt: date(3_600))
      _ = try await coordinator.synchronize(familyID: fixture.familyID)
      #expect(try await database.read { try PendingCommand.fetchOne($0)?.deferrals } == 1)
      _ = try await coordinator.synchronize(familyID: fixture.familyID)
    }
    #expect(await responder.requests.count == 3)
    let state = try await database.read { db in
      (try PendingCommand.fetchCount(db), try SyncConflict.fetchCount(db), try SleepSession.find(fixture.sessionID).fetchOne(db))
    }
    #expect(state.0 == 0)
    #expect(state.1 == 0)
    #expect(state.2?.endedAt == date(3_600))
  }

  @Test func deferredCommandBecomesAConflictAfterADay() async throws {
    let fixture = try await seedAuthoritativeSession(revision: 1, endedAt: nil)
    let responder = ScriptedResponder { index, request in
      if let command = request.commands.first {
        return SyncResponse(commandResults: [APICommandResult(id: command.id, status: "rejected", error: "active sleep not found")],
          events: [], nextCursor: request.cursor, hasMore: false, serverTime: date(20_000))
      }
      return SyncResponse(commandResults: [], events: [], nextCursor: request.cursor, hasMore: false,
        serverTime: date(20_000 + 25 * 3_600))
    }
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }
    try await withDependencies { $0.apiClient = api } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      try await coordinator.endSleep(familyID: fixture.familyID, sessionID: fixture.sessionID, endedAt: date(3_600))
      _ = try await coordinator.synchronize(familyID: fixture.familyID)
      _ = try await coordinator.synchronize(familyID: fixture.familyID)
    }
    let conflicts = try await database.read { try SyncConflict.fetchAll($0) }
    expectNoDifference(conflicts.map(\.commandKind), ["endSleep"])
    expectNoDifference(conflicts.map(\.reason), ["active sleep not found"])
    #expect(try await database.read { try PendingCommand.fetchCount($0) } == 0)
  }

  @Test func journalDropsCommandsAcknowledgedBeforeTheServerCutoff() async throws {
    let fixture = try await seedAuthoritativeSession(revision: 1, endedAt: date(3_600))
    let responder = ScriptedResponder { index, request in
      let command = try #require(request.commands.first)
      let revision = index + 1
      let serverTime = index == 1 ? date(1_000) : date(100_000)
      var response = SyncResponse(
        commandResults: [APICommandResult(id: command.id, status: "accepted",
          entityID: EntityID(rawValue: fixture.sessionID.rawValue),
          payload: try jsonValue(serverSleep(fixture: fixture, revision: revision, endedAt: date(4_200))))],
        events: [], nextCursor: request.cursor, hasMore: false, serverTime: serverTime)
      response.journalRetentionCutoff = index == 1 ? nil : date(50_000)
      return response
    }
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }
    var acknowledged: [PendingCommand.ID] = []
    try await withDependencies { $0.apiClient = api } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      for _ in 0..<2 {
        try await coordinator.upsertSleep(familyID: fixture.familyID, childID: fixture.childID,
          sessionID: fixture.sessionID, startedAt: date(600), endedAt: date(4_200))
        acknowledged.append(try await database.read { try PendingCommand.fetchOne($0)?.id }!)
        _ = try await coordinator.synchronize(familyID: fixture.familyID)
      }
    }
    let journal = try await database.read { try AcknowledgedCommand.fetchAll($0) }
    expectNoDifference(journal.map(\.id), [acknowledged[1]])
    expectNoDifference(journal.map(\.acknowledgedAt), [date(100_000)])
  }

  @Test(arguments: ["accepted", "rejected"])
  func retriedCommandResultCannotReplaceANewerAuthoritativeRevision(status: String) async throws {
    let fixture = try await seedAuthoritativeSession(revision: 3, endedAt: date(3_600))
    var api = APIClient.testValue
    api.sync = { _, _, request in
      let command = try #require(request.commands.first)
      return SyncResponse(
        commandResults: [APICommandResult(id: command.id, status: status,
          error: status == "rejected" ? "stale revision" : nil,
          entityID: EntityID(rawValue: fixture.sessionID.rawValue),
          payload: try jsonValue(serverSleep(fixture: fixture, revision: 1, endedAt: nil)))],
        events: [], nextCursor: request.cursor, hasMore: false, serverTime: date(6_000)
      )
    }
    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(rawValue: UUID(-10)), accessToken: { "token" })
      try await coordinator.upsertSleep(familyID: fixture.familyID, childID: fixture.childID,
        sessionID: fixture.sessionID, startedAt: date(600), endedAt: date(4_200))
      _ = try await coordinator.synchronize(familyID: fixture.familyID)
    }
    let state = try await database.read { database in
      (try SleepSession.find(fixture.sessionID).fetchOne(database),
       try PendingCommand.fetchCount(database), try AcknowledgedCommand.fetchCount(database),
       try SyncConflict.fetchCount(database))
    }
    expectNoDifference(state.0?.revision, 3)
    expectNoDifference(state.0?.endedAt, date(3_600))
    expectNoDifference(state.1, 0)
    expectNoDifference(state.2, status == "accepted" ? 1 : 0)
    expectNoDifference(state.3, status == "rejected" ? 1 : 0)
  }

  @Test func midnightQuietHoursRemainVisibleWhileOffline() async throws {
    let familyID = Family.ID(rawValue: UUID(-201))
    let childID = Child.ID(rawValue: UUID(-202))
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    let coordinator = SyncCoordinator(deviceID: DeviceID(), accessToken: { "token" })
    try await coordinator.updateChild(familyID: familyID, childID: childID, nickname: "Muru",
      birthDate: date(0), predictionMode: "adaptive", manualIntervalMinutes: nil,
      quietHoursStartMinutes: 0, quietHoursEndMinutes: 0, timeZone: "UTC", growthReference: "none")
    let child = try await database.read { try Child.find(childID).fetchOne($0) }
    expectNoDifference(child?.quietHoursStartMinutes, 0)
    expectNoDifference(child?.quietHoursEndMinutes, 0)
  }

  @Test(arguments: [false, true])
  func offlineSleepCommandsKeepInsertionOrderWhenTimeDoesNotIncrease(clockRollsBack: Bool) async throws {
    let fixture = Fixture(familyID: Family.ID(rawValue: UUID(-1)), childID: Child.ID(rawValue: UUID(-2)), sessionID: SleepSession.ID(rawValue: UUID(-3)))
    try await seedFamilyAndChild(familyID: fixture.familyID, childID: fixture.childID)
    let coordinator = SyncCoordinator(deviceID: DeviceID(), accessToken: { "token" })
    try await coordinator.startSleep(familyID: fixture.familyID, childID: fixture.childID,
      sessionID: fixture.sessionID, commandID: PendingCommand.ID(rawValue: UUID(100)), startedAt: date(1_000))
    try await withDependencies {
      $0.date.now = clockRollsBack ? date(9_000) : date(10_000)
    } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(), accessToken: { "token" })
      try await coordinator.endSleep(familyID: fixture.familyID, sessionID: fixture.sessionID, endedAt: date(3_600))
    }
    let state = try await database.read { database in
      (try SleepSession.find(fixture.sessionID).fetchOne(database),
       try PendingCommand.order(by: \.sequence).fetchAll(database))
    }
    expectNoDifference(state.0?.endedAt, date(3_600))
    expectNoDifference(state.1.map(\.kind), ["startSleep", "endSleep"])
    expectNoDifference(state.1.map(\.sequence), [1, 2])
    expectNoDifference(state.1.map(\.expectedRevision), [nil, 1])
    #expect(state.1[1].id.uuidString < state.1[0].id.uuidString)
  }

  @Test func sleepAndGrowthEditsQueueSequentialRevisionsWhileOffline() async throws {
    let fixture = try await seedAuthoritativeSession(revision: 3, endedAt: date(3_600))
    let coordinator = SyncCoordinator(deviceID: DeviceID(), accessToken: { "token" })
    for endedAt in [date(4_000), date(4_200)] {
      try await coordinator.upsertSleep(familyID: fixture.familyID, childID: fixture.childID,
        sessionID: fixture.sessionID, startedAt: date(1_000), endedAt: endedAt)
    }
    let measurementID = GrowthMeasurement.ID(rawValue: UUID(-20))
    for weight in [6_000, 6_100] {
      try await coordinator.upsertGrowthMeasurement(familyID: fixture.familyID, childID: fixture.childID,
        measurementID: measurementID, measuredAt: date(1_000), weightGrams: weight, heightMillimeters: nil)
    }
    try await coordinator.deleteGrowthMeasurement(familyID: fixture.familyID, measurementID: measurementID)
    let pending = try await database.read { try PendingCommand.order(by: \.sequence).fetchAll($0) }
    expectNoDifference(pending.map(\.expectedRevision), [3, 4, nil, 1, 2])
  }

  @Test func incompleteAcknowledgementCannotDiscardPendingIntent() async throws {
    let fixture = try await seedAuthoritativeSession(revision: 3, endedAt: date(3_600))
    var api = APIClient.testValue
    api.sync = { _, _, request in
      SyncResponse(commandResults: request.commands.map {
        APICommandResult(id: $0.id, status: "accepted", entityID: nil, payload: nil)
      }, events: [], nextCursor: request.cursor, hasMore: false, serverTime: date(6_000))
    }
    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(), accessToken: { "token" })
      try await coordinator.upsertSleep(familyID: fixture.familyID, childID: fixture.childID,
        sessionID: fixture.sessionID, startedAt: date(600), endedAt: date(4_200))
      await #expect(throws: SyncError.invalidServerPayload) {
        try await coordinator.synchronize(familyID: fixture.familyID)
      }
    }
    let state = try await database.read { database in
      (try PendingCommand.fetchCount(database), try AcknowledgedCommand.fetchCount(database),
       try SleepSession.find(fixture.sessionID).fetchOne(database))
    }
    expectNoDifference(state.0, 1)
    expectNoDifference(state.1, 0)
    expectNoDifference(state.2?.endedAt, date(4_200))
  }

  @Test(arguments: ["sleepSession", "growthMeasurement", "temperatureReading"])
  func completeDeleteTombstoneSettlesTheOutboxAndSurvivesARebuild(entityType: String) async throws {
    let fixture = Fixture(familyID: Family.ID(rawValue: UUID(-1)), childID: Child.ID(rawValue: UUID(-2)), sessionID: SleepSession.ID(rawValue: UUID(-3)))
    try await seedFamilyAndChild(familyID: fixture.familyID, childID: fixture.childID)
    let entityID = EntityID(rawValue: fixture.sessionID.rawValue)
    let payload: JSONValue
    let kind: String
    switch entityType {
    case "sleepSession":
      var sleep = serverSleep(fixture: fixture, revision: 2, endedAt: date(3_600))
      sleep.deletedAt = date(5_000)
      payload = try jsonValue(sleep)
      kind = "deleteSleep"
    case "growthMeasurement":
      payload = try jsonValue(ServerGrowthMeasurementPayload(id: GrowthMeasurement.ID(rawValue: entityID.rawValue),
        familyID: fixture.familyID, childID: fixture.childID, measuredAt: date(1_000), weightGrams: 6_000,
        heightMillimeters: nil, note: "", revision: 2, updatedAt: date(5_000), deletedAt: date(5_000)))
      kind = "deleteGrowthMeasurement"
    default:
      payload = try jsonValue(ServerTemperatureReadingPayload(id: TemperatureReading.ID(rawValue: entityID.rawValue),
        familyID: fixture.familyID, childID: fixture.childID, measuredAt: date(1_000), centiCelsius: 3_700,
        note: "", revision: 2, updatedAt: date(5_000), deletedAt: date(5_000)))
      kind = "deleteTemperatureReading"
    }
    let commandID = PendingCommand.ID(rawValue: UUID(-10))
    let commandPayload = try JSONEncoder.uneton.encode(DeleteCommandPayload(id: entityID))
    try await database.write { database in
      try PendingCommand.insert {
        PendingCommand(id: commandID, familyID: fixture.familyID, kind: kind,
          expectedRevision: 1, payloadJSON: commandPayload, createdAt: date(4_000), sequence: 1)
      }.execute(database)
    }
    var api = APIClient.testValue
    api.sync = { _, _, _ in
      SyncResponse(commandResults: [APICommandResult(id: commandID, status: "accepted", entityID: entityID, payload: payload)],
        events: [SyncEvent(cursor: 1, entityType: entityType, entityID: entityID, operation: "delete",
          revision: 2, payload: payload, createdAt: date(5_000))],
        nextCursor: 1, hasMore: false, serverTime: date(6_000))
    }
    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(), accessToken: { "token" })
      _ = try await coordinator.synchronize(familyID: fixture.familyID)
      let cursor = try await coordinator.cursor(familyID: fixture.familyID)
      expectNoDifference(cursor, 1)
    }
    try await database.write { try Projection.rebuild(familyID: fixture.familyID, database: $0) }
    let state = try await database.read { database in
      (try PendingCommand.fetchCount(database), try AcknowledgedCommand.fetchCount(database),
       try AuthoritativeRecord.find(AuthoritativeRecord.ID(rawValue: "\(entityType):\(entityID.uuidString)")).fetchOne(database),
       try SleepSession.fetchCount(database), try GrowthMeasurement.fetchCount(database), try TemperatureReading.fetchCount(database))
    }
    expectNoDifference(state.0, 0)
    expectNoDifference(state.1, 1)
    expectNoDifference(state.2?.revision, 2)
    expectNoDifference(state.2?.operation, "delete")
    expectNoDifference([state.3, state.4, state.5], [0, 0, 0])
  }

  @Test func restoreReplaysAcknowledgedStartAndWakeInTheirOriginalSequence() async throws {
    let fixture = Fixture(familyID: Family.ID(rawValue: UUID(-1)), childID: Child.ID(rawValue: UUID(-2)), sessionID: SleepSession.ID(rawValue: UUID(-3)))
    try await seedFamilyAndChild(familyID: fixture.familyID, childID: fixture.childID)
    let responder = SnapshotRecoveryResponder(fixture: fixture)
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }
    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: DeviceID(), accessToken: { "token" })
      try await coordinator.startSleep(familyID: fixture.familyID, childID: fixture.childID,
        sessionID: fixture.sessionID, commandID: PendingCommand.ID(rawValue: UUID(100)), startedAt: date(1_000))
      try await coordinator.endSleep(familyID: fixture.familyID, sessionID: fixture.sessionID, endedAt: date(3_600))
      _ = try await coordinator.synchronize(familyID: fixture.familyID)
      _ = try await coordinator.synchronize(familyID: fixture.familyID)
    }
    let state = try await database.read { database in
      (try PendingCommand.fetchCount(database),
       try AcknowledgedCommand.order(by: \.sequence).fetchAll(database),
       try SleepSession.find(fixture.sessionID).fetchOne(database))
    }
    expectNoDifference(state.0, 0)
    expectNoDifference(state.1.map(\.kind), ["startSleep", "endSleep"])
    expectNoDifference(state.1.map(\.sequence), [1, 2])
    expectNoDifference(state.2?.endedAt, date(3_600))
    expectNoDifference(state.2?.revision, 2)
    let commandCounts = await responder.commandCounts
    expectNoDifference(commandCounts, [2, 0, 2])
  }

  private func seedAuthoritativeSession(revision: Int, endedAt: Date?) async throws -> Fixture {
    let fixture = Fixture(familyID: Family.ID(rawValue: UUID(-1)), childID: Child.ID(rawValue: UUID(-2)), sessionID: SleepSession.ID(rawValue: UUID(-3)))
    try await seedFamilyAndChild(familyID: fixture.familyID, childID: fixture.childID)
    let payload = serverSleep(fixture: fixture, revision: revision, endedAt: endedAt)
    let payloadJSON = try JSONEncoder.uneton.encode(payload)
    try await database.write { database in
      try AuthoritativeRecord.insert {
        AuthoritativeRecord(
          id: "sleepSession:\(fixture.sessionID.uuidString)",
          familyID: fixture.familyID,
          entityType: "sleepSession",
          entityID: EntityID(rawValue: fixture.sessionID.rawValue),
          revision: revision,
          operation: "upsert",
          payloadJSON: payloadJSON
        )
      }.execute(database)
      try Projection.rebuild(familyID: fixture.familyID, database: database)
    }
    return fixture
  }

  private func seedFamilyAndChild(familyID: Family.ID, childID: Child.ID) async throws {
    let child = ServerChildPayload(
      id: childID,
      nickname: "Muru",
      birthDate: "2026-02-23",
      predictionMode: "adaptive",
      quietHoursStartMinutes: 1_200,
      quietHoursEndMinutes: 360,
      revision: 1,
      updatedAt: date(0)
    )
    let childJSON = try JSONEncoder.uneton.encode(child)
    try await database.write { database in
      try Family.insert { ModelFixtures.family(id: familyID, name: "Home", updatedAt: date(0)) }.execute(database)
      try AuthoritativeRecord.insert {
        AuthoritativeRecord(
          id: "child:\(childID.uuidString)",
          familyID: familyID,
          entityType: "child",
          entityID: EntityID(rawValue: childID.rawValue),
          revision: 1,
          operation: "upsert",
          payloadJSON: childJSON
        )
      }.execute(database)
      try Projection.rebuild(familyID: familyID, database: database)
    }
  }
}

private struct Fixture: Sendable {
  var familyID: Family.ID
  var childID: Child.ID
  var sessionID: SleepSession.ID
}

private enum TestTransportError: Error, Equatable {
  case offline
}

private actor CollisionResponder {
  private(set) var requestCount = 0
  let fixture: Fixture

  init(fixture: Fixture) { self.fixture = fixture }

  func response(for request: SyncRequest) throws -> SyncResponse {
    requestCount += 1
    let command = try #require(request.commands.first)
    let revision = requestCount == 1 ? 3 : 4
    let endedAt = requestCount == 1 ? date(3_600) : date(3_500)
    return SyncResponse(
      commandResults: [
        APICommandResult(
          id: command.id,
          status: "rejected",
          error: "stale revision",
          entityID: EntityID(rawValue: fixture.sessionID.rawValue),
          payload: try jsonValue(serverSleep(fixture: fixture, revision: revision, endedAt: endedAt))
        )
      ],
      events: [],
      nextCursor: request.cursor,
      hasMore: false,
      serverTime: date(6_000 + Double(requestCount))
    )
  }
}

private actor PaginationResponder {
  private(set) var requestCount = 0
  private(set) var commandCounts: [Int] = []
  let fixture: Fixture

  init(fixture: Fixture) { self.fixture = fixture }

  func response(for request: SyncRequest) throws -> SyncResponse {
    requestCount += 1
    commandCounts.append(request.commands.count)
    let revision = requestCount
    let endedAt: Date? = requestCount == 1 ? nil : date(3_600)
    return SyncResponse(
      commandResults: [],
      events: [
        SyncEvent(
          cursor: Int64(requestCount),
          entityType: "sleepSession",
          entityID: EntityID(rawValue: fixture.sessionID.rawValue),
          operation: "upsert",
          revision: revision,
          payload: try jsonValue(serverSleep(fixture: fixture, revision: revision, endedAt: endedAt)),
          createdAt: date(Double(requestCount))
        )
      ],
      nextCursor: Int64(requestCount),
      hasMore: requestCount == 1,
      serverTime: date(6_000 + Double(requestCount))
    )
  }
}

private actor SlowResponder {
  private(set) var requestCount = 0

  func response(for request: SyncRequest) async throws -> SyncResponse {
    requestCount += 1
    try await Task.sleep(for: .milliseconds(50))
    return SyncResponse(
      commandResults: [], events: [], nextCursor: request.cursor,
      hasMore: false, serverTime: date(6_000)
    )
  }
}

private actor PausedResponder {
  private(set) var commandCounts: [Int] = []
  private let fixture: Fixture
  private var started = false
  private var startedWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  init(fixture: Fixture) { self.fixture = fixture }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startedWaiter = $0 }
  }

  func release() {
    releaseWaiter?.resume()
    releaseWaiter = nil
  }

  func response(for request: SyncRequest) async throws -> SyncResponse {
    commandCounts.append(request.commands.count)
    if commandCounts.count == 1 {
      started = true
      startedWaiter?.resume()
      startedWaiter = nil
      await withCheckedContinuation { releaseWaiter = $0 }
      return SyncResponse(
        commandResults: [], events: [], nextCursor: request.cursor,
        hasMore: false, serverTime: date(6_000)
      )
    }
    let command = try #require(request.commands.first)
    let payload = try jsonValue(serverSleep(fixture: fixture, revision: 1, endedAt: nil))
    return SyncResponse(
      commandResults: [APICommandResult(
        id: command.id, status: "accepted", entityID: EntityID(rawValue: fixture.sessionID.rawValue), payload: payload
      )],
      events: [SyncEvent(
        cursor: 1, entityType: "sleepSession", entityID: EntityID(rawValue: fixture.sessionID.rawValue),
        operation: "upsert", revision: 1, payload: payload, createdAt: date(6_001)
      )],
      nextCursor: 1, hasMore: false, serverTime: date(6_001)
    )
  }
}

private actor BatchResponder {
  private(set) var batchSizes: [Int] = []

  func response(for request: SyncRequest) throws -> SyncResponse {
    batchSizes.append(request.commands.count)
    return SyncResponse(
      commandResults: try request.commands.map { command in
        let input = try JSONDecoder.uneton.decode(ChildCommandPayload.self, from: JSONEncoder.uneton.encode(command.payload))
        let payload = ServerChildPayload(id: input.id, nickname: input.nickname, birthDate: input.birthDate,
          predictionMode: input.predictionMode, manualIntervalMinutes: input.manualIntervalMinutes,
          quietHoursStartMinutes: input.quietHoursStartMinutes, quietHoursEndMinutes: input.quietHoursEndMinutes,
          timeZone: input.timeZone, growthReference: input.growthReference, revision: 1, updatedAt: date(6_000))
        return APICommandResult(id: command.id, status: "accepted",
          entityID: EntityID(rawValue: input.id.rawValue), payload: try jsonValue(payload))
      },
      events: [], nextCursor: request.cursor, hasMore: false, serverTime: date(6_000)
    )
  }
}

private actor SnapshotRecoveryResponder {
  private(set) var commandCounts: [Int] = []
  private var requestCount = 0
  let fixture: Fixture

  init(fixture: Fixture) { self.fixture = fixture }

  func response(for request: SyncRequest) throws -> SyncResponse {
    requestCount += 1
    commandCounts.append(request.commands.count)
    switch requestCount {
    case 1:
      return try commandResponse(request, generation: "generation-before-restore")
    case 2:
      let child = ServerChildPayload(
        id: fixture.childID,
        nickname: "Muru",
        birthDate: "2026-02-23",
        predictionMode: "adaptive",
        quietHoursStartMinutes: 1_200,
        quietHoursEndMinutes: 360,
        revision: 1,
        updatedAt: date(0)
      )
      return SyncResponse(
        commandResults: [], events: [], nextCursor: 0, hasMore: false, serverTime: date(2_100),
        generation: "generation-after-restore",
        snapshot: FamilySnapshot(
          cursor: 0,
          entities: [SnapshotEntity(entityType: "child", entityID: EntityID(rawValue: fixture.childID.rawValue), revision: 1, payload: try jsonValue(child))],
          createdAt: date(2_100)
        ),
        resetRequired: true
      )
    default:
      return try commandResponse(request, generation: "generation-after-restore")
    }
  }

  private func commandResponse(_ request: SyncRequest, generation: String) throws -> SyncResponse {
    #expect(!request.commands.isEmpty)
    let payloads = try request.commands.enumerated().map { index, command in
      try jsonValue(serverSleep(fixture: fixture, revision: index + 1,
        endedAt: command.kind == "endSleep" ? date(3_600) : nil))
    }
    return SyncResponse(
      commandResults: request.commands.enumerated().map { index, command in
        APICommandResult(id: command.id, status: "accepted",
          entityID: EntityID(rawValue: fixture.sessionID.rawValue), payload: payloads[index])
      },
      events: request.commands.enumerated().map { index, _ in
        SyncEvent(cursor: Int64(index + 1), entityType: "sleepSession",
          entityID: EntityID(rawValue: fixture.sessionID.rawValue), operation: "upsert",
          revision: index + 1, payload: payloads[index], createdAt: date(2_000))
      },
      nextCursor: Int64(request.commands.count), hasMore: false, serverTime: date(2_200), generation: generation
    )
  }
}

private actor ScriptedResponder {
  private(set) var requests: [SyncRequest] = []
  let script: @Sendable (Int, SyncRequest) async throws -> SyncResponse

  init(_ script: @escaping @Sendable (Int, SyncRequest) async throws -> SyncResponse) { self.script = script }

  func response(for request: SyncRequest) async throws -> SyncResponse {
    requests.append(request)
    return try await script(requests.count, request)
  }
}

private func endResponse(_ request: SyncRequest, fixture: Fixture, cursor: Int64, revision: Int) throws -> SyncResponse {
  let command = try #require(request.commands.first)
  let ended = try jsonValue(serverSleep(fixture: fixture, revision: revision, endedAt: date(3_600)))
  return SyncResponse(
    commandResults: [APICommandResult(id: command.id, status: "accepted",
      entityID: EntityID(rawValue: fixture.sessionID.rawValue), payload: ended)],
    events: [SyncEvent(cursor: cursor, entityType: "sleepSession",
      entityID: EntityID(rawValue: fixture.sessionID.rawValue), operation: "upsert",
      revision: revision, payload: ended, createdAt: date(3_700))],
    nextCursor: cursor, hasMore: false, serverTime: date(3_700))
}

private func sleepCommandPayload(_ command: APICommand) throws -> SleepCommandPayload {
  try JSONDecoder.uneton.decode(SleepCommandPayload.self, from: JSONEncoder.uneton.encode(command.payload))
}

private func serverSleep(fixture: Fixture, revision: Int, endedAt: Date?) -> ServerSleepPayload {
  ServerSleepPayload(
    id: fixture.sessionID,
    familyID: fixture.familyID,
    childID: fixture.childID,
    startedAt: date(0),
    endedAt: endedAt,
    revision: revision,
    authorID: UserID(rawValue: UUID(-4)),
    source: "phone",
    updatedAt: date(4_500)
  )
}

private func jsonValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
  try JSONDecoder.uneton.decode(JSONValue.self, from: JSONEncoder.uneton.encode(value))
}

private func date(_ seconds: TimeInterval) -> Date {
  Date(timeIntervalSince1970: 1_700_000_000 + seconds)
}
