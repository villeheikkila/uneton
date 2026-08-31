import Dependencies
import Foundation
import SQLiteData

public actor SyncCoordinator {
  @Dependency(\.defaultDatabase) private var database
  @Dependency(\.apiClient) private var apiClient
  @Dependency(\.date.now) private var now
  @Dependency(\.uuid) private var uuid

  private let deviceID: UUID
  private let accessToken: @Sendable () -> String?
  private var synchronizationTasks: [Family.ID: Task<SleepForecast?, Error>] = [:]

  public init(deviceID: UUID, accessToken: @escaping @Sendable () -> String?) {
    self.deviceID = deviceID
    self.accessToken = accessToken
  }

  @discardableResult
  public func createChild(
    familyID: Family.ID,
    nickname: String,
    birthDate: Date
  ) async throws -> Child.ID {
    let childID = uuid()
    let commandID = uuid()
    let payload = try jsonValue(
      ChildCommandPayload(
        id: childID,
        nickname: nickname,
        birthDate: SyncPayload.birthDateFormatter.string(from: birthDate),
        predictionMode: "adaptive",
        manualIntervalMinutes: nil,
        quietHoursStartMinutes: 1_200,
        quietHoursEndMinutes: 360,
        timeZone: TimeZone.current.identifier
      )
    )
    let pending = try pendingCommand(id: commandID, familyID: familyID, kind: "createChild", payload: payload)
    try await database.write { database in
      try PendingCommand.insert { pending }.execute(database)
      try Projection.rebuild(familyID: familyID, database: database)
    }
    return childID
  }

  @discardableResult
  public func startSleep(
    familyID: Family.ID,
    childID: Child.ID,
    startedAt: Date? = nil,
    source: String = "phone"
  ) async throws -> SleepSession.ID {
    let sessionID = uuid()
    let commandID = uuid()
    let start = startedAt ?? now
    let payload = try jsonValue(SleepCommandPayload(id: sessionID, childID: childID, startedAt: start, endedAt: nil, source: source))
    let pending = try pendingCommand(id: commandID, familyID: familyID, kind: "startSleep", payload: payload)
    try await database.write { database in
      try PendingCommand.insert { pending }.execute(database)
      try Projection.rebuild(familyID: familyID, database: database)
    }
    return sessionID
  }

  public func endSleep(
    familyID: Family.ID,
    sessionID: SleepSession.ID,
    endedAt: Date? = nil,
    wakeMood: String = "unknown",
    wakeReason: String = "unknown",
    caregiverIntervened: Bool? = nil
  ) async throws {
    let end = endedAt ?? now
    let session = try await database.read { database in
      try SleepSession.find(sessionID).fetchOne(database)
    }
    guard let session else { throw SyncError.missingSession }
    guard end > session.startedAt else { throw SyncError.invalidInterval }
    let commandID = uuid()
    let payload = try jsonValue(SleepCommandPayload(id: sessionID, childID: session.childID, startedAt: session.startedAt, endedAt: end, source: session.source, startCondition: session.startCondition, sleepLocation: session.sleepLocation, endCondition: session.endCondition, wakeMood: wakeMood, wakeReason: wakeReason, caregiverIntervened: caregiverIntervened))
    let pending = try pendingCommand(id: commandID, familyID: familyID, kind: "endSleep", expectedRevision: session.revision == 0 ? nil : session.revision, payload: payload)
    try await database.write { database in
      try PendingCommand.insert { pending }.execute(database)
      try Projection.rebuild(familyID: familyID, database: database)
    }
  }

  public func upsertSleep(
    familyID: Family.ID,
    childID: Child.ID,
    sessionID: SleepSession.ID? = nil,
    startedAt: Date,
    endedAt: Date?
  ) async throws {
    if let endedAt, endedAt <= startedAt { throw SyncError.invalidInterval }
    let id = sessionID ?? uuid()
    let existing = try await database.read { database in try SleepSession.find(id).fetchOne(database) }
    let commandID = uuid()
    let payload = try jsonValue(SleepCommandPayload(
      id: id,
      childID: childID,
      startedAt: startedAt,
      endedAt: endedAt,
      source: existing?.source ?? "manual",
      startCondition: existing?.startCondition ?? "",
      sleepLocation: existing?.sleepLocation ?? "",
      endCondition: existing?.endCondition ?? "",
      wakeMood: existing?.wakeMood ?? "unknown",
      wakeReason: existing?.wakeReason ?? "unknown",
      caregiverIntervened: existing?.caregiverIntervened
    ))
    let pending = try pendingCommand(id: commandID, familyID: familyID, kind: "upsertSleep", expectedRevision: existing?.revision == 0 ? nil : existing?.revision, payload: payload)
    try await database.write { database in
      try PendingCommand.insert { pending }.execute(database)
      try Projection.rebuild(familyID: familyID, database: database)
    }
  }

  public func synchronize(familyID: Family.ID) async throws -> SleepForecast? {
    if let task = synchronizationTasks[familyID] {
      return try await task.value
    }
    let task = Task { try await self.performSynchronization(familyID: familyID) }
    synchronizationTasks[familyID] = task
    do {
      let forecast = try await task.value
      synchronizationTasks[familyID] = nil
      return forecast
    } catch {
      synchronizationTasks[familyID] = nil
      throw error
    }
  }

  public func cursor(familyID: Family.ID) async throws -> Int64 {
    try await database.read { database in
      try SyncState.find(familyID).fetchOne(database)?.cursor ?? 0
    }
  }

  public func generation(familyID: Family.ID) async throws -> String {
    try await database.read { database in
      try SyncState.find(familyID).fetchOne(database)?.generation ?? ""
    }
  }

  private func performSynchronization(familyID: Family.ID) async throws -> SleepForecast? {
    guard let token = accessToken(), !token.isEmpty else { throw SyncError.notAuthenticated }
    var forecast: SleepForecast?
    var shouldContinue = true
    var includeCommands = true
    var commandPasses = 0
    while shouldContinue {
      let snapshot = try await database.read { database -> (Int64, String, [PendingCommand]) in
        let state = try SyncState.find(familyID).fetchOne(database)
        let commands = try PendingCommand
          .where { $0.familyID.eq(familyID) }
          .order(by: \.createdAt)
          .fetchAll(database)
        return (state?.cursor ?? 0, state?.generation ?? "", Array(commands.prefix(100)))
      }
      let commands = includeCommands ? try snapshot.2.map(apiCommand) : []
      if includeCommands { commandPasses += 1 }
      let response = try await apiClient.sync(
        familyID,
        token,
        SyncRequest(cursor: snapshot.0, generation: snapshot.1, deviceID: deviceID, commands: commands)
      )
      try Self.validate(response, after: snapshot.0, generation: snapshot.1, commandIDs: Set(commands.map(\.id)))
      try await apply(response, familyID: familyID)
      forecast = response.sleepForecast ?? response.nextSleepEstimate.map {
        SleepForecast(nextSleepEstimate: $0)
      }
      if response.hasMore {
        shouldContinue = true
        includeCommands = false
      } else {
        let hasPending = try await database.read { database in
          try PendingCommand.where { $0.familyID.eq(familyID) }.fetchCount(database) > 0
        }
        shouldContinue = hasPending && commandPasses < 100
        includeCommands = shouldContinue
      }
    }
    return forecast
  }

  private func apply(_ response: SyncResponse, familyID: Family.ID) async throws {
    let appliedAt = now
    let replacementIDs = Dictionary(uniqueKeysWithValues: response.commandResults.map { ($0.id, uuid()) })
    try await database.write { database in
      let currentState = try SyncState.find(familyID).fetchOne(database)
      let currentCursor = currentState?.cursor ?? 0
      if let snapshot = response.snapshot {
        try AuthoritativeRecord.where { $0.familyID.eq(familyID) }.delete().execute(database)
        for entity in snapshot.entities {
          let record = AuthoritativeRecord(
            id: "\(entity.entityType):\(entity.entityID.uuidString)",
            familyID: familyID,
            entityType: entity.entityType,
            entityID: entity.entityID,
            revision: entity.revision,
            operation: "upsert",
            payloadJSON: try JSONEncoder.uneton.encode(entity.payload)
          )
          try AuthoritativeRecord.upsert { record }.execute(database)
        }
      }
      if response.resetRequired {
        let acknowledged = try AcknowledgedCommand
          .where { $0.familyID.eq(familyID) }
          .order(by: \.createdAt)
          .fetchAll(database)
        for command in acknowledged {
          try PendingCommand.upsert {
            PendingCommand(
              id: command.id,
              familyID: command.familyID,
              kind: command.kind,
              expectedRevision: command.expectedRevision,
              payloadJSON: command.payloadJSON,
              createdAt: command.createdAt
            )
          }.execute(database)
        }
      }
      for result in response.commandResults {
        guard let command = try PendingCommand.find(result.id).fetchOne(database) else { continue }
        try Self.ingestResultPayload(result, command: command, familyID: familyID, database: database)
        if result.status == "accepted" {
          try AcknowledgedCommand.upsert {
            AcknowledgedCommand(
              id: command.id,
              familyID: command.familyID,
              kind: command.kind,
              expectedRevision: command.expectedRevision,
              payloadJSON: command.payloadJSON,
              createdAt: command.createdAt,
              acknowledgedAt: appliedAt
            )
          }.execute(database)
          try PendingCommand.find(result.id).delete().execute(database)
        } else {
          try PendingCommand.find(result.id).delete().execute(database)
          let resolution = try Self.automaticResolution(
            result,
            command: command,
            replacementID: replacementIDs[result.id]!,
            appliedAt: appliedAt
          )
          switch resolution {
          case let .retry(replacement):
            try PendingCommand.insert { replacement }.execute(database)
          case .serverWins:
            break
          case .requiresUser:
            let identity = try Self.commandIdentity(command)
            let serverPayload = try result.payload.map { try JSONEncoder.uneton.encode($0) }
            try SyncConflict.upsert {
              SyncConflict(
                id: command.id,
                familyID: familyID,
                entityType: identity.entityType,
                entityID: identity.entityID,
                commandKind: command.kind,
                expectedRevision: command.expectedRevision,
                localPayloadJSON: command.payloadJSON,
                serverPayloadJSON: serverPayload,
                reason: result.error ?? "The server rejected this change.",
                createdAt: appliedAt
              )
            }.execute(database)
          }
        }
      }
      let eventBaseline = response.snapshot?.cursor ?? currentCursor
      for event in response.events {
        guard event.cursor > eventBaseline else { continue }
        let payload = try JSONEncoder.uneton.encode(event.payload)
        let record = AuthoritativeRecord(
          id: "\(event.entityType):\(event.entityID.uuidString)",
          familyID: familyID,
          entityType: event.entityType,
          entityID: event.entityID,
          revision: event.revision,
          operation: event.operation,
          payloadJSON: payload
        )
        let existing = try AuthoritativeRecord.find(record.id).fetchOne(database)
        if existing == nil || existing!.revision <= record.revision {
          try AuthoritativeRecord.upsert { record }.execute(database)
        }
      }
      let cursor = response.resetRequired ? response.nextCursor : max(currentCursor, response.nextCursor)
      let state = SyncState(id: familyID, cursor: cursor, generation: response.generation, lastSyncedAt: response.serverTime)
      try SyncState.upsert { state }.execute(database)
      try Projection.rebuild(familyID: familyID, database: database)
    }
  }

  private nonisolated static func validate(
    _ response: SyncResponse,
    after cursor: Int64,
    generation: String,
    commandIDs: Set<UUID>
  ) throws {
    guard !response.generation.isEmpty else { throw SyncError.invalidServerPayload }
    if response.resetRequired {
      guard response.snapshot != nil, response.commandResults.isEmpty, !response.hasMore else {
        throw SyncError.invalidServerPayload
      }
    } else {
      guard (generation.isEmpty || response.generation == generation), response.nextCursor >= cursor else {
        throw SyncError.invalidServerPayload
      }
    }
    guard !response.hasMore || !response.events.isEmpty else { throw SyncError.invalidServerPayload }
    if let snapshot = response.snapshot {
      guard snapshot.cursor <= response.nextCursor else { throw SyncError.invalidServerPayload }
    }
    var previous = response.snapshot?.cursor ?? cursor
    for event in response.events {
      guard event.cursor > previous, event.cursor <= response.nextCursor else {
        throw SyncError.invalidServerPayload
      }
      previous = event.cursor
    }
    var resultIDs = Set<UUID>()
    for result in response.commandResults {
      guard commandIDs.contains(result.id), resultIDs.insert(result.id).inserted else {
        throw SyncError.invalidServerPayload
      }
    }
    if !response.resetRequired, resultIDs != commandIDs {
      throw SyncError.invalidServerPayload
    }
  }

  public func resolveConflict(_ conflictID: SyncConflict.ID, resolution: SyncConflictResolution) async throws {
    let replacementID = uuid()
    let resolvedAt = now
    try await database.write { database in
      guard let conflict = try SyncConflict.find(conflictID).fetchOne(database) else { return }
      if resolution == .keepMine {
        let revision = try conflict.serverPayloadJSON.flatMap(Self.revision)
        let replacement = PendingCommand(
          id: replacementID,
          familyID: conflict.familyID,
          kind: conflict.commandKind,
          expectedRevision: revision,
          payloadJSON: conflict.localPayloadJSON,
          createdAt: resolvedAt,
          rebaseAttempt: 1
        )
        try PendingCommand.insert { replacement }.execute(database)
      }
      try SyncConflict.find(conflictID).delete().execute(database)
      try Projection.rebuild(familyID: conflict.familyID, database: database)
    }
  }

  private nonisolated static func ingestResultPayload(
    _ result: APICommandResult,
    command: PendingCommand,
    familyID: Family.ID,
    database: Database
  ) throws {
    guard let payload = result.payload else { return }
    let identity = try commandIdentity(command)
    let payloadData = try JSONEncoder.uneton.encode(payload)
    let entityID = result.entityID ?? identity.entityID
    guard let revision = try revision(payloadData) else { return }
    try AuthoritativeRecord.upsert {
      AuthoritativeRecord(
        id: "\(identity.entityType):\(entityID.uuidString)",
        familyID: familyID,
        entityType: identity.entityType,
        entityID: entityID,
        revision: revision,
        operation: "upsert",
        payloadJSON: payloadData
      )
    }.execute(database)
  }

  private nonisolated static func automaticResolution(
    _ result: APICommandResult,
    command: PendingCommand,
    replacementID: UUID,
    appliedAt: Date
  ) throws -> AutomaticResolution {
    guard let serverPayload = result.payload else { return .requiresUser }
    guard command.rebaseAttempt == 0 else { return .requiresUser }
    let serverData = try JSONEncoder.uneton.encode(serverPayload)
    guard let serverRevision = try revision(serverData) else { return .requiresUser }
    switch command.kind {
    case "deleteSleep":
      let server = try JSONDecoder.uneton.decode(ServerSleepPayload.self, from: serverData)
      guard server.deletedAt == nil else { return .serverWins }
      return .retry(PendingCommand(
        id: replacementID,
        familyID: command.familyID,
        kind: command.kind,
        expectedRevision: serverRevision,
        payloadJSON: command.payloadJSON,
        createdAt: appliedAt,
        rebaseAttempt: 1
      ))
    case "updateChild", "updatePredictionSettings":
      return .retry(PendingCommand(
        id: replacementID,
        familyID: command.familyID,
        kind: command.kind,
        expectedRevision: serverRevision,
        payloadJSON: command.payloadJSON,
        createdAt: appliedAt,
        rebaseAttempt: 1
      ))
    case "endSleep":
      let local = try JSONDecoder.uneton.decode(SleepCommandPayload.self, from: command.payloadJSON)
      let server = try JSONDecoder.uneton.decode(ServerSleepPayload.self, from: serverData)
      guard let localEnd = local.endedAt, let serverEnd = server.endedAt else { return .requiresUser }
      guard localEnd < serverEnd else { return .serverWins }
      let merged = SleepCommandPayload(
        id: server.id,
        childID: server.childID,
        startedAt: server.startedAt,
        endedAt: localEnd,
        source: server.source,
        startCondition: server.startCondition,
        sleepLocation: server.sleepLocation,
        endCondition: local.endCondition,
        wakeMood: local.wakeMood,
        wakeReason: local.wakeReason,
        caregiverIntervened: local.caregiverIntervened
      )
      return .retry(PendingCommand(
        id: replacementID,
        familyID: command.familyID,
        kind: "upsertSleep",
        expectedRevision: serverRevision,
        payloadJSON: try JSONEncoder.uneton.encode(merged),
        createdAt: appliedAt,
        rebaseAttempt: 1
      ))
    default:
      return .requiresUser
    }
  }

  private nonisolated static func commandIdentity(_ command: PendingCommand) throws -> (entityType: String, entityID: UUID) {
    switch command.kind {
    case "createChild", "updateChild", "updatePredictionSettings":
      return ("child", try JSONDecoder.uneton.decode(ChildCommandPayload.self, from: command.payloadJSON).id)
    case "startSleep", "endSleep", "upsertSleep":
      return ("sleepSession", try JSONDecoder.uneton.decode(SleepCommandPayload.self, from: command.payloadJSON).id)
    case "deleteSleep":
      return ("sleepSession", try JSONDecoder.uneton.decode(DeleteCommandPayload.self, from: command.payloadJSON).id)
    default:
      throw SyncError.invalidServerPayload
    }
  }

  private nonisolated static func revision(_ data: Data) throws -> Int? {
    guard case let .object(object) = try JSONDecoder.uneton.decode(JSONValue.self, from: data),
          case let .number(value)? = object["revision"]
    else { return nil }
    return Int(value)
  }

  private func pendingCommand(
    id: UUID,
    familyID: Family.ID,
    kind: String,
    expectedRevision: Int? = nil,
    payload: JSONValue
  ) throws -> PendingCommand {
    PendingCommand(
      id: id,
      familyID: familyID,
      kind: kind,
      expectedRevision: expectedRevision,
      payloadJSON: try JSONEncoder.uneton.encode(payload),
      createdAt: now
    )
  }

  private func apiCommand(_ command: PendingCommand) throws -> APICommand {
    APICommand(
      id: command.id,
      kind: command.kind,
      expectedRevision: command.expectedRevision,
      payload: try JSONDecoder.uneton.decode(JSONValue.self, from: command.payloadJSON)
    )
  }

  private func jsonValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
    let data = try JSONEncoder.uneton.encode(value)
    return try JSONDecoder.uneton.decode(JSONValue.self, from: data)
  }

}

public enum SyncConflictResolution: Sendable {
  case keepMine
  case keepServer
}

private enum AutomaticResolution {
  case retry(PendingCommand)
  case serverWins
  case requiresUser
}

public enum SyncError: Error, Equatable {
  case notAuthenticated
  case missingSession
  case invalidInterval
  case invalidServerPayload
}

struct ChildCommandPayload: Codable {
  var id: UUID
  var nickname: String
  var birthDate: String
  var predictionMode: String
  var manualIntervalMinutes: Int?
  var quietHoursStartMinutes: Int
  var quietHoursEndMinutes: Int
  var timeZone: String = TimeZone.current.identifier
}

struct SleepCommandPayload: Codable {
  var id: UUID
  var childID: UUID
  var startedAt: Date
  var endedAt: Date?
  var source: String
  var startCondition: String = ""
  var sleepLocation: String = ""
  var endCondition: String = ""
  var wakeMood: String = "unknown"
  var wakeReason: String = "unknown"
  var caregiverIntervened: Bool?
}

struct DeleteCommandPayload: Codable {
  var id: UUID
}

struct ServerChildPayload: Codable {
  var id: UUID
  var nickname: String
  var birthDate: String
  var predictionMode: String
  var manualIntervalMinutes: Int?
  var quietHoursStartMinutes: Int
  var quietHoursEndMinutes: Int
  var timeZone: String = TimeZone.current.identifier
  var revision: Int
  var updatedAt: Date
}

struct ServerSleepPayload: Codable {
  var id: UUID
  var familyID: UUID
  var childID: UUID
  var startedAt: Date
  var endedAt: Date?
  var revision: Int
  var authorID: UUID
  var source: String
  var startCondition: String = ""
  var sleepLocation: String = ""
  var endCondition: String = ""
  var wakeMood: String = "unknown"
  var wakeReason: String = "unknown"
  var caregiverIntervened: Bool?
  var supersededByID: UUID?
  var updatedAt: Date
  var deletedAt: Date?
}
