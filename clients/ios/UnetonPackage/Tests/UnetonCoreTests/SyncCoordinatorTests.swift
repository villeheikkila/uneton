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

  @Test func synchronizationReturnsTheServerForecast() async throws {
    let familyID = UUID(-1)
    let childID = UUID(-2)
    let activeSleepID = UUID(-3)
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
      try await SyncCoordinator(deviceID: UUID(-10), accessToken: { "token" })
        .synchronize(familyID: familyID)
    }

    #expect(actual == expected)
  }

  @Test func authoritativeBaseReplaysPendingOverlay() async throws {
    let fixture = try await seedAuthoritativeSession(revision: 2, endedAt: date(3_600))
    let command = PendingCommand(
      id: UUID(10),
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
      SleepSession(
        id: fixture.sessionID,
        familyID: fixture.familyID,
        childID: fixture.childID,
        startedAt: date(300),
        endedAt: date(3_900),
        revision: 2,
        authorID: UUID(-4),
        source: "manual",
        updatedAt: date(5_000),
        pendingCommandID: UUID(10)
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
            entityID: fixture.sessionID,
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
      let coordinator = SyncCoordinator(deviceID: UUID(-10), accessToken: { "token" })
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
    let familyID = UUID(-21)
    let childID = UUID(-22)
    let measurementID = UUID(-23)
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
          entityType: "growthMeasurement", entityID: measurementID, revision: 2,
          operation: "upsert", payloadJSON: authoritativeJSON
        )
      }.execute(database)
      try PendingCommand.insert {
        PendingCommand(
          id: UUID(-24), familyID: familyID, kind: "upsertGrowthMeasurement",
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
    #expect(projected?.pendingCommandID == UUID(-24))
  }

  @Test func growthReferenceReplaysPendingChildUpdate() async throws {
    let familyID = UUID(-61)
    let childID = UUID(-62)
    try await seedFamilyAndChild(familyID: familyID, childID: childID)

    try await SyncCoordinator(deviceID: UUID(-63), accessToken: { "token" })
      .updateGrowthReference(familyID: familyID, childID: childID, growthReference: "girl")

    let child = try await database.read { database in try Child.find(childID).fetchOne(database) }
    #expect(child?.growthReference == "girl")
    let pending = try await database.read { database in
      try PendingCommand.where { $0.familyID.eq(familyID) }.fetchAll(database)
    }
    #expect(pending.count == 1)
    #expect(pending.first?.kind == "updateChild")
  }

  @Test func acceptedGrowthReferenceUpdatePersistsServerValue() async throws {
    let familyID = UUID(-67)
    let childID = UUID(-68)
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
            entityID: childID,
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
      let coordinator = SyncCoordinator(deviceID: UUID(-69), accessToken: { "token" })
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
    let familyID = UUID(-64)
    let childID = UUID(-65)
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
      _ = try await SyncCoordinator(deviceID: UUID(-66), accessToken: { "token" }).synchronize(familyID: familyID)
    }
    let point = try await database.read { database in
      try GrowthReferencePoint.find("girl:height:6:0").fetchOne(database)
    }
    #expect(point?.value == 676)
  }

  @Test func duplicateStartRemapsToCanonicalServerSession() async throws {
    let familyID = UUID(-1)
    let childID = UUID(-2)
    let canonicalID = UUID(-3)
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    var optimisticID: UUID?
    var api = APIClient.testValue
    api.sync = { _, _, request in
      let command = try #require(request.commands.first)
      return SyncResponse(
        commandResults: [
          APICommandResult(
            id: command.id,
            status: "accepted",
            entityID: canonicalID,
            payload: try jsonValue(
              ServerSleepPayload(
                id: canonicalID,
                familyID: familyID,
                childID: childID,
                startedAt: date(1_000),
                endedAt: nil,
                revision: 1,
                authorID: UUID(-4),
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
      let coordinator = SyncCoordinator(deviceID: UUID(-10), accessToken: { "token" })
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
    let conflict = SyncConflict(
      id: UUID(-20),
      familyID: fixture.familyID,
      entityType: "sleepSession",
      entityID: fixture.sessionID,
      commandKind: "upsertSleep",
      expectedRevision: 3,
      localPayloadJSON: localPayload,
      serverPayloadJSON: serverPayload,
      reason: "stale revision",
      createdAt: date(5_000)
    )
    try await database.write { try SyncConflict.insert { conflict }.execute($0) }

    let coordinator = SyncCoordinator(deviceID: UUID(-10), accessToken: { "token" })
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
      let coordinator = SyncCoordinator(deviceID: UUID(-10), accessToken: { "token" })
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

  @Test func paginationAppliesEveryPageAndAdvancesCursor() async throws {
    let fixture = Fixture(familyID: UUID(-1), childID: UUID(-2), sessionID: UUID(-3))
    try await seedFamilyAndChild(familyID: fixture.familyID, childID: fixture.childID)
    let responder = PaginationResponder(fixture: fixture)
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }

    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: UUID(-10), accessToken: { "token" })
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
    let familyID = UUID(-1)
    let childID = UUID(-2)
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    let responder = SlowResponder()
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }

    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: UUID(-10), accessToken: { "token" })
      async let first = coordinator.synchronize(familyID: familyID)
      async let second = coordinator.synchronize(familyID: familyID)
      _ = try await (first, second)
    }

    #expect(await responder.requestCount == 1)
  }

  @Test func malformedCursorResponseLeavesDurableCommandUntouched() async throws {
    let familyID = UUID(-1)
    let childID = UUID(-2)
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
      let coordinator = SyncCoordinator(deviceID: UUID(-10), accessToken: { "token" })
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

  @Test func networkFailureKeepsOptimisticStateAndCommandForRetry() async throws {
    let familyID = UUID(-1)
    let childID = UUID(-2)
    try await seedFamilyAndChild(familyID: familyID, childID: childID)
    var api = APIClient.testValue
    api.sync = { _, _, _ in throw TestTransportError.offline }

    var optimisticID: UUID?
    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: UUID(-10), accessToken: { "token" })
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
    let familyID = UUID(-1)
    try await database.write { database in
      try Family.insert { Family(id: familyID, name: "Home", role: "owner", updatedAt: date(0)) }.execute(database)
      for index in 0..<101 {
        let childID = UUID(index + 1_000)
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
            id: UUID(index + 2_000),
            familyID: familyID,
            kind: "createChild",
            payloadJSON: payloadJSON,
            createdAt: date(Double(index))
          )
        }.execute(database)
      }
    }
    let responder = BatchResponder()
    var api = APIClient.testValue
    api.sync = { _, _, request in await responder.response(for: request) }

    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: UUID(-10), accessToken: { "token" })
      _ = try await coordinator.synchronize(familyID: familyID)
    }

    #expect(await responder.batchSizes == [100, 1])
    #expect(try await database.read { try PendingCommand.fetchCount($0) } == 0)
  }

  @Test func snapshotRecoveryReplaysAcknowledgedCommandsAfterServerRollback() async throws {
    let fixture = Fixture(familyID: UUID(-1), childID: UUID(-2), sessionID: UUID(-3))
    try await seedFamilyAndChild(familyID: fixture.familyID, childID: fixture.childID)
    let responder = SnapshotRecoveryResponder(fixture: fixture)
    var api = APIClient.testValue
    api.sync = { _, _, request in try await responder.response(for: request) }

    try await withDependencies {
      $0.apiClient = api
    } operation: {
      let coordinator = SyncCoordinator(deviceID: UUID(-10), accessToken: { "token" })
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

  private func seedAuthoritativeSession(revision: Int, endedAt: Date?) async throws -> Fixture {
    let fixture = Fixture(familyID: UUID(-1), childID: UUID(-2), sessionID: UUID(-3))
    try await seedFamilyAndChild(familyID: fixture.familyID, childID: fixture.childID)
    let payload = serverSleep(fixture: fixture, revision: revision, endedAt: endedAt)
    let payloadJSON = try JSONEncoder.uneton.encode(payload)
    try await database.write { database in
      try AuthoritativeRecord.insert {
        AuthoritativeRecord(
          id: "sleepSession:\(fixture.sessionID)",
          familyID: fixture.familyID,
          entityType: "sleepSession",
          entityID: fixture.sessionID,
          revision: revision,
          operation: "upsert",
          payloadJSON: payloadJSON
        )
      }.execute(database)
      try Projection.rebuild(familyID: fixture.familyID, database: database)
    }
    return fixture
  }

  private func seedFamilyAndChild(familyID: UUID, childID: UUID) async throws {
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
      try Family.insert { Family(id: familyID, name: "Home", role: "owner", updatedAt: date(0)) }.execute(database)
      try AuthoritativeRecord.insert {
        AuthoritativeRecord(
          id: "child:\(childID)",
          familyID: familyID,
          entityType: "child",
          entityID: childID,
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
  var familyID: UUID
  var childID: UUID
  var sessionID: UUID
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
          entityID: fixture.sessionID,
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
          entityID: fixture.sessionID,
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

private actor BatchResponder {
  private(set) var batchSizes: [Int] = []

  func response(for request: SyncRequest) -> SyncResponse {
    batchSizes.append(request.commands.count)
    return SyncResponse(
      commandResults: request.commands.map {
        APICommandResult(id: $0.id, status: "accepted", entityID: nil, payload: nil)
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
      let command = try #require(request.commands.first)
      return SyncResponse(
        commandResults: [
          APICommandResult(
            id: command.id,
            status: "accepted",
            entityID: fixture.sessionID,
            payload: try jsonValue(serverSleep(fixture: fixture, revision: 1, endedAt: nil))
          )
        ],
        events: [], nextCursor: 1, hasMore: false, serverTime: date(2_000),
        generation: "generation-before-restore"
      )
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
          entities: [SnapshotEntity(entityType: "child", entityID: fixture.childID, revision: 1, payload: try jsonValue(child))],
          createdAt: date(2_100)
        ),
        resetRequired: true
      )
    default:
      let command = try #require(request.commands.first)
      return SyncResponse(
        commandResults: [
          APICommandResult(
            id: command.id,
            status: "accepted",
            entityID: fixture.sessionID,
            payload: try jsonValue(serverSleep(fixture: fixture, revision: 1, endedAt: nil))
          )
        ],
        events: [], nextCursor: 1, hasMore: false, serverTime: date(2_200),
        generation: "generation-after-restore"
      )
    }
  }
}

private func serverSleep(fixture: Fixture, revision: Int, endedAt: Date?) -> ServerSleepPayload {
  ServerSleepPayload(
    id: fixture.sessionID,
    familyID: fixture.familyID,
    childID: fixture.childID,
    startedAt: date(0),
    endedAt: endedAt,
    revision: revision,
    authorID: UUID(-4),
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
