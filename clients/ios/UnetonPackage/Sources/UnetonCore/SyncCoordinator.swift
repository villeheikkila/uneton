import Dependencies
import Foundation
import SQLiteData
import Tagged

public actor SyncCoordinator {
  private enum SynchronizationFlightTag {}
  @Dependency(\.defaultDatabase) private var database
  @Dependency(\.apiClient) private var apiClient
  @Dependency(\.date.now) private var now
  @Dependency(\.uuid) private var uuid

  private let deviceID: DeviceID
  private let accessToken: @Sendable () -> String?
  private struct SynchronizationFlight {
    let id: Tagged<SynchronizationFlightTag, UUID>
    let task: Task<SleepForecast?, Error>
  }
  private var synchronizationTasks: [Family.ID: SynchronizationFlight] = [:]

  public init(deviceID: DeviceID, accessToken: @escaping @Sendable () -> String?) {
    self.deviceID = deviceID
    self.accessToken = accessToken
  }

  @discardableResult
  public func createChild(
    familyID: Family.ID,
    nickname: String,
    birthDate: Date,
    growthReference: String = "none"
  ) async throws -> Child.ID {
    guard ["none", "girl", "boy"].contains(growthReference) else { throw SyncError.invalidGrowthReference }
    let childID: Child.ID = nextID()
    let commandID: PendingCommand.ID = nextID()
    let payload = try jsonValue(
      ChildCommandPayload(
        id: childID,
        nickname: nickname,
        birthDate: SyncPayload.birthDateFormatter.string(from: birthDate),
        predictionMode: "adaptive",
        manualIntervalMinutes: nil,
        quietHoursStartMinutes: 1_200,
        quietHoursEndMinutes: 360,
        timeZone: TimeZone.current.identifier,
        growthReference: growthReference
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
    let sessionID: SleepSession.ID = nextID()
    let commandID: PendingCommand.ID = nextID()
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
    let commandID: PendingCommand.ID = nextID()
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
    let id = sessionID ?? nextID()
    let existing = try await database.read { database in try SleepSession.find(id).fetchOne(database) }
    let commandID: PendingCommand.ID = nextID()
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

  public func upsertGrowthMeasurement(
    familyID: Family.ID,
    childID: Child.ID,
    measurementID: GrowthMeasurement.ID? = nil,
    measuredAt: Date,
    weightGrams: Int?,
    heightMillimeters: Int?,
    note: String = ""
  ) async throws {
    guard weightGrams != nil || heightMillimeters != nil else { throw SyncError.invalidGrowthMeasurement }
    guard weightGrams.map({ 100...100_000 ~= $0 }) ?? true,
          heightMillimeters.map({ 100...2_500 ~= $0 }) ?? true
    else { throw SyncError.invalidGrowthMeasurement }
    let id = measurementID ?? nextID()
    let existing = try await database.read { database in try GrowthMeasurement.find(id).fetchOne(database) }
    let payload = try jsonValue(GrowthMeasurementCommandPayload(
      id: id, childID: childID, measuredAt: measuredAt, weightGrams: weightGrams,
      heightMillimeters: heightMillimeters, note: note
    ))
    let pending = try pendingCommand(
      id: nextID(), familyID: familyID, kind: "upsertGrowthMeasurement",
      expectedRevision: existing?.revision == 0 ? nil : existing?.revision, payload: payload
    )
    try await database.write { database in
      try PendingCommand.insert { pending }.execute(database)
      try Projection.rebuild(familyID: familyID, database: database)
    }
  }

  public func deleteGrowthMeasurement(
    familyID: Family.ID,
    measurementID: GrowthMeasurement.ID
  ) async throws {
    let existing = try await database.read { database in try GrowthMeasurement.find(measurementID).fetchOne(database) }
    guard let existing else { throw SyncError.missingGrowthMeasurement }
    let payload = try jsonValue(DeleteCommandPayload(id: measurementID))
    let pending = try pendingCommand(
      id: nextID(), familyID: familyID, kind: "deleteGrowthMeasurement",
      expectedRevision: existing.revision == 0 ? nil : existing.revision, payload: payload
    )
    try await database.write { database in
      try PendingCommand.insert { pending }.execute(database)
      try Projection.rebuild(familyID: familyID, database: database)
    }
  }

  public func upsertTemperatureReading(
    familyID: Family.ID, childID: Child.ID, readingID: TemperatureReading.ID? = nil,
    measuredAt: Date, centiCelsius: Int, note: String = "", expectedRevision: Int? = nil
  ) async throws {
    guard TemperatureValue.isValid(centiCelsius) else { throw SyncError.invalidTemperatureReading }
    let id = readingID ?? nextID()
    let existing = try await database.read { database in try TemperatureReading.find(id).fetchOne(database) }
    let effectiveRevision = try await pendingTemperatureRevision(familyID: familyID, readingID: id)
      ?? expectedRevision ?? (existing?.revision == 0 ? nil : existing?.revision)
    let payload = try jsonValue(TemperatureReadingCommandPayload(id: id, childID: childID,
      measuredAt: measuredAt, centiCelsius: centiCelsius, note: note))
    let pending = try pendingCommand(id: nextID(), familyID: familyID, kind: "upsertTemperatureReading",
      expectedRevision: effectiveRevision, payload: payload)
    try await database.write { database in
      try PendingCommand.insert { pending }.execute(database)
      try Projection.rebuild(familyID: familyID, database: database)
    }
  }

  public func deleteTemperatureReading(familyID: Family.ID, readingID: TemperatureReading.ID,
                                       expectedRevision: Int? = nil) async throws {
    let existing = try await database.read { database in try TemperatureReading.find(readingID).fetchOne(database) }
    guard let existing else { throw SyncError.missingTemperatureReading }
    let effectiveRevision = try await pendingTemperatureRevision(familyID: familyID, readingID: readingID)
      ?? expectedRevision ?? (existing.revision == 0 ? nil : existing.revision)
    let payload = try jsonValue(DeleteCommandPayload(id: readingID))
    let pending = try pendingCommand(id: nextID(), familyID: familyID, kind: "deleteTemperatureReading",
      expectedRevision: effectiveRevision, payload: payload)
    try await database.write { database in
      try PendingCommand.insert { pending }.execute(database)
      try Projection.rebuild(familyID: familyID, database: database)
    }
  }

  private func pendingTemperatureRevision(familyID: Family.ID, readingID: TemperatureReading.ID) async throws -> Int? {
    try await database.read { database in
      let commands = try PendingCommand.where { $0.familyID.eq(familyID) }.fetchAll(database)
        .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
      let matching = commands.filter { command in
        guard command.kind == "upsertTemperatureReading",
              let payload = try? JSONDecoder.uneton.decode(TemperatureReadingCommandPayload.self, from: command.payloadJSON)
        else { return false }
        return payload.id == readingID
      }
      guard let last = matching.last else { return nil }
      return (last.expectedRevision ?? 0) + 1
    }
  }

  public func updateGrowthReference(
    familyID: Family.ID,
    childID: Child.ID,
    growthReference: String
  ) async throws {
    guard ["none", "girl", "boy"].contains(growthReference) else { throw SyncError.invalidGrowthReference }
    let child = try await database.read { database in try Child.find(childID).fetchOne(database) }
    guard let child else { throw SyncError.missingChild }
    let payload = try jsonValue(ChildCommandPayload(
      id: child.id, nickname: child.nickname,
      birthDate: SyncPayload.birthDateFormatter.string(from: child.birthDate),
      predictionMode: child.predictionMode, manualIntervalMinutes: child.manualIntervalMinutes,
      quietHoursStartMinutes: child.quietHoursStartMinutes,
      quietHoursEndMinutes: child.quietHoursEndMinutes, timeZone: child.timeZone,
      growthReference: growthReference
    ))
    let pending = try pendingCommand(
      id: nextID(), familyID: familyID, kind: "updateChild",
      expectedRevision: child.revision == 0 ? nil : child.revision, payload: payload
    )
    try await database.write { database in
      try PendingCommand.insert { pending }.execute(database)
      try Projection.rebuild(familyID: familyID, database: database)
    }
  }

  public func synchronize(familyID: Family.ID) async throws -> SleepForecast? {
    let flight: SynchronizationFlight
    if let existing = synchronizationTasks[familyID] {
      flight = existing
    } else {
      flight = SynchronizationFlight(
        id: Tagged<SynchronizationFlightTag, UUID>(),
        task: Task { try await self.performSynchronization(familyID: familyID) }
      )
      synchronizationTasks[familyID] = flight
    }
    let forecast: SleepForecast?
    do {
      forecast = try await flight.task.value
    } catch {
      if synchronizationTasks[familyID]?.id == flight.id {
        synchronizationTasks[familyID] = nil
      }
      throw error
    }
    if synchronizationTasks[familyID]?.id == flight.id {
      synchronizationTasks[familyID] = nil
    }
    // A command can arrive after the flight's final outbox read. A caller joining
    // that flight must not report success while its newly queued intent is unsent.
    let hasPending = try await database.read { database in
      try PendingCommand.where { $0.familyID.eq(familyID) }.fetchCount(database) > 0
    }
    if hasPending {
      return try await synchronize(familyID: familyID)
    }
    return forecast
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
      try Self.validate(response, for: familyID, after: snapshot.0, generation: snapshot.1, commands: commands)
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
        if hasPending && commandPasses >= 100 { throw SyncError.incompleteSynchronization }
        shouldContinue = hasPending
        includeCommands = shouldContinue
      }
    }
    return forecast
  }

  private func apply(_ response: SyncResponse, familyID: Family.ID) async throws {
    let appliedAt = now
    let replacementIDs = Dictionary(uniqueKeysWithValues: response.commandResults.map { ($0.id, nextID() as PendingCommand.ID) })
    try await database.write { database in
      if !response.growthReferencePoints.isEmpty {
        try GrowthReferencePoint.delete().execute(database)
        for point in response.growthReferencePoints {
          try GrowthReferencePoint.upsert {
            GrowthReferencePoint(reference: point.reference, metric: point.metric, ageMonths: point.ageMonths, sd: point.sd, value: point.value)
          }.execute(database)
        }
      }
      let currentState = try SyncState.find(familyID).fetchOne(database)
      let currentCursor = currentState?.cursor ?? 0
      if let snapshot = response.snapshot {
        try AuthoritativeRecord.where { $0.familyID.eq(familyID) }.delete().execute(database)
        for entity in snapshot.entities {
          let record = AuthoritativeRecord(
            id: AuthoritativeRecord.ID(rawValue: "\(entity.entityType):\(entity.entityID.uuidString)"),
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
                id: SyncConflict.ID(rawValue: command.id.rawValue),
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
          id: AuthoritativeRecord.ID(rawValue: "\(event.entityType):\(event.entityID.uuidString)"),
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
    for familyID: Family.ID,
    after cursor: Int64,
    generation: String,
    commands: [APICommand]
  ) throws {
    guard !response.generation.isEmpty, response.nextCursor >= 0 else { throw SyncError.invalidServerPayload }
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
      guard snapshot.cursor >= 0, snapshot.cursor <= response.nextCursor,
            response.resetRequired || snapshot.cursor >= cursor else { throw SyncError.invalidServerPayload }
      var identities = Set<String>()
      for entity in snapshot.entities {
        let identity = "\(entity.entityType):\(entity.entityID.uuidString)"
        guard identities.insert(identity).inserted,
              validEntity(entity.entityType, id: entity.entityID, revision: entity.revision, payload: entity.payload, familyID: familyID)
        else { throw SyncError.invalidServerPayload }
      }
    }
    var previous = response.snapshot?.cursor ?? cursor
    for event in response.events {
      guard event.cursor > previous, event.cursor <= response.nextCursor,
            event.operation == "upsert" || event.operation == "delete",
            validEntity(event.entityType, id: event.entityID, revision: event.revision, payload: event.payload, familyID: familyID) else {
        throw SyncError.invalidServerPayload
      }
      previous = event.cursor
    }
    guard response.nextCursor == previous,
          !response.hasMore || response.nextCursor > cursor else {
      throw SyncError.invalidServerPayload
    }
    let commandByID = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
    var resultIDs = Set<PendingCommand.ID>()
    for result in response.commandResults {
      guard let command = commandByID[result.id], resultIDs.insert(result.id).inserted,
            result.status == "accepted" || result.status == "rejected" else {
        throw SyncError.invalidServerPayload
      }
      if let payload = result.payload {
        guard let type = entityType(for: command.kind),
              case let .object(commandObject) = command.payload,
              case let .string(commandIDValue)? = commandObject["id"],
              let commandEntityID = EntityID(uuidString: commandIDValue),
              case let .object(resultObject) = payload,
              case let .number(revisionValue)? = resultObject["revision"],
              let revision = Int(exactly: revisionValue),
              validEntity(
                type, id: result.entityID ?? commandEntityID, revision: revision,
                payload: payload, familyID: familyID
              ) else { throw SyncError.invalidServerPayload }
      }
    }
    if !response.resetRequired, resultIDs != Set(commandByID.keys) {
      throw SyncError.invalidServerPayload
    }
  }

  private nonisolated static func entityType(for kind: String) -> String? {
    switch kind {
    case "createChild", "updateChild", "updatePredictionSettings": "child"
    case "startSleep", "endSleep", "upsertSleep", "deleteSleep": "sleepSession"
    case "upsertGrowthMeasurement", "deleteGrowthMeasurement": "growthMeasurement"
    case "upsertTemperatureReading", "deleteTemperatureReading": "temperatureReading"
    default: nil
    }
  }

  private nonisolated static func validEntity(
    _ type: String,
    id: EntityID,
    revision: Int,
    payload: JSONValue,
    familyID: Family.ID
  ) -> Bool {
    guard revision > 0 else { return false }
    guard let data = try? JSONEncoder.uneton.encode(payload) else { return false }
    switch type {
    case "child":
      guard let child = try? JSONDecoder.uneton.decode(ServerChildPayload.self, from: data) else { return false }
      return child.id.rawValue == id.rawValue && child.revision == revision
    case "sleepSession":
      guard let sleep = try? JSONDecoder.uneton.decode(ServerSleepPayload.self, from: data) else { return false }
      return sleep.id.rawValue == id.rawValue && sleep.familyID == familyID && sleep.revision == revision
    case "growthMeasurement":
      guard let measurement = try? JSONDecoder.uneton.decode(ServerGrowthMeasurementPayload.self, from: data) else { return false }
      return measurement.id.rawValue == id.rawValue && measurement.familyID == familyID && measurement.revision == revision
    case "temperatureReading":
      guard let reading = try? JSONDecoder.uneton.decode(ServerTemperatureReadingPayload.self, from: data) else { return false }
      return reading.id.rawValue == id.rawValue && reading.familyID == familyID && reading.revision == revision
    default:
      return false
    }
  }

  public func resolveConflict(_ conflictID: SyncConflict.ID, resolution: SyncConflictResolution) async throws {
    let replacementID: PendingCommand.ID = nextID()
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
        id: AuthoritativeRecord.ID(rawValue: "\(identity.entityType):\(entityID.uuidString)"),
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
    replacementID: PendingCommand.ID,
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
    case "upsertGrowthMeasurement", "deleteGrowthMeasurement", "upsertTemperatureReading", "deleteTemperatureReading":
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

  private nonisolated static func commandIdentity(_ command: PendingCommand) throws -> (entityType: String, entityID: EntityID) {
    switch command.kind {
    case "createChild", "updateChild", "updatePredictionSettings":
      return ("child", try EntityID(rawValue: JSONDecoder.uneton.decode(ChildCommandPayload.self, from: command.payloadJSON).id.rawValue))
    case "startSleep", "endSleep", "upsertSleep":
      return ("sleepSession", try EntityID(rawValue: JSONDecoder.uneton.decode(SleepCommandPayload.self, from: command.payloadJSON).id.rawValue))
    case "deleteSleep":
      return ("sleepSession", try EntityID(rawValue: JSONDecoder.uneton.decode(DeleteCommandPayload<SleepSession.ID>.self, from: command.payloadJSON).id.rawValue))
    case "upsertGrowthMeasurement":
      return ("growthMeasurement", try EntityID(rawValue: JSONDecoder.uneton.decode(GrowthMeasurementCommandPayload.self, from: command.payloadJSON).id.rawValue))
    case "deleteGrowthMeasurement":
      return ("growthMeasurement", try EntityID(rawValue: JSONDecoder.uneton.decode(DeleteCommandPayload<GrowthMeasurement.ID>.self, from: command.payloadJSON).id.rawValue))
    case "upsertTemperatureReading":
      return ("temperatureReading", try EntityID(rawValue: JSONDecoder.uneton.decode(TemperatureReadingCommandPayload.self, from: command.payloadJSON).id.rawValue))
    case "deleteTemperatureReading":
      return ("temperatureReading", try EntityID(rawValue: JSONDecoder.uneton.decode(DeleteCommandPayload<TemperatureReading.ID>.self, from: command.payloadJSON).id.rawValue))
    default:
      throw SyncError.invalidServerPayload
    }
  }

  private nonisolated static func revision(_ data: Data) throws -> Int? {
    guard case let .object(object) = try JSONDecoder.uneton.decode(JSONValue.self, from: data),
          case let .number(value)? = object["revision"]
    else { return nil }
    return Int(exactly: value)
  }

  private func pendingCommand(
    id: PendingCommand.ID,
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

  private func nextID<Tag>() -> Tagged<Tag, UUID> {
    Tagged(rawValue: uuid())
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
  case invalidGrowthMeasurement
  case missingGrowthMeasurement
  case invalidTemperatureReading
  case missingTemperatureReading
  case missingChild
  case invalidGrowthReference
  case incompleteSynchronization
}

struct ChildCommandPayload: Codable {
  var id: Child.ID
  var nickname: String
  var birthDate: String
  var predictionMode: String
  var manualIntervalMinutes: Int?
  var quietHoursStartMinutes: Int
  var quietHoursEndMinutes: Int
  var timeZone: String = TimeZone.current.identifier
  var growthReference: String = "none"
}

struct SleepCommandPayload: Codable {
  var id: SleepSession.ID
  var childID: Child.ID
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

struct DeleteCommandPayload<ID: Codable>: Codable {
  var id: ID
}

struct GrowthMeasurementCommandPayload: Codable {
  var id: GrowthMeasurement.ID
  var childID: Child.ID
  var measuredAt: Date
  var weightGrams: Int?
  var heightMillimeters: Int?
  var note: String
}

struct TemperatureReadingCommandPayload: Codable {
  var id: TemperatureReading.ID
  var childID: Child.ID
  var measuredAt: Date
  var centiCelsius: Int
  var note: String
}

struct ServerChildPayload: Codable {
  var id: Child.ID
  var nickname: String
  var birthDate: String
  var predictionMode: String
  var manualIntervalMinutes: Int?
  var quietHoursStartMinutes: Int
  var quietHoursEndMinutes: Int
  var timeZone: String = TimeZone.current.identifier
  var growthReference: String = "none"
  var revision: Int
  var updatedAt: Date
}

struct ServerSleepPayload: Codable {
  var id: SleepSession.ID
  var familyID: Family.ID
  var childID: Child.ID
  var startedAt: Date
  var endedAt: Date?
  var revision: Int
  var authorID: UserID
  var source: String
  var startCondition: String = ""
  var sleepLocation: String = ""
  var endCondition: String = ""
  var wakeMood: String = "unknown"
  var wakeReason: String = "unknown"
  var caregiverIntervened: Bool?
  var supersededByID: SleepSession.ID?
  var updatedAt: Date
  var deletedAt: Date?
}

struct ServerGrowthMeasurementPayload: Codable {
  var id: GrowthMeasurement.ID
  var familyID: Family.ID
  var childID: Child.ID
  var measuredAt: Date
  var weightGrams: Int?
  var heightMillimeters: Int?
  var note: String
  var revision: Int
  var updatedAt: Date
  var deletedAt: Date?
}

struct ServerTemperatureReadingPayload: Codable {
  var id: TemperatureReading.ID
  var familyID: Family.ID
  var childID: Child.ID
  var measuredAt: Date
  var centiCelsius: Int
  var note: String
  var revision: Int
  var updatedAt: Date
  var deletedAt: Date?
}
