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
      try Self.enqueue(pending, database: database)
      try Projection.refresh(familyID: familyID, keys: [Projection.key(for: pending)], database: database)
    }
    return childID
  }

  @discardableResult
  public func startSleep(
    familyID: Family.ID,
    childID: Child.ID,
    sessionID: SleepSession.ID? = nil,
    commandID: PendingCommand.ID? = nil,
    startedAt: Date? = nil,
    source: String = "phone"
  ) async throws -> SleepSession.ID {
    let sessionID: SleepSession.ID = sessionID ?? nextID()
    let commandID: PendingCommand.ID = commandID ?? nextID()
    let start = startedAt ?? now
    let payload = try jsonValue(SleepCommandPayload(id: sessionID, childID: childID, startedAt: start, endedAt: nil, source: source))
    let pending = try pendingCommand(id: commandID, familyID: familyID, kind: "startSleep", payload: payload)
    try await database.write { database in
      try Self.enqueue(pending, database: database)
      try Projection.refresh(familyID: familyID, keys: [Projection.key(for: pending)], database: database)
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
    let pending = try pendingCommand(id: commandID, familyID: familyID, kind: "endSleep", payload: payload)
    let fallbackRevision = max(1, session.revision)
    try await database.write { database in
      try Self.enqueue(pending, reserving: "sleepSession", EntityID(rawValue: sessionID.rawValue), fallback: fallbackRevision, database: database)
      try Projection.refresh(familyID: familyID, keys: [Projection.key(for: pending)], database: database)
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
    let pending = try pendingCommand(id: commandID, familyID: familyID, kind: "upsertSleep", payload: payload)
    let fallbackRevision = existing?.revision
    try await database.write { database in
      try Self.enqueue(pending, reserving: "sleepSession", EntityID(rawValue: id.rawValue), fallback: fallbackRevision, database: database)
      try Projection.refresh(familyID: familyID, keys: [Projection.key(for: pending)], database: database)
    }
  }

  /// Enqueue the entire import atomically. Stable identities make reselecting an export safe.
  @discardableResult
  public func importHuckleberry(familyID: Family.ID, childID: Child.ID, history: HuckleberryImport) async throws -> Int {
    let commands = try history.sleeps.map { sleep in
      let id = sleep.sessionID(familyID: familyID, childID: childID)
      let payload = try jsonValue(SleepCommandPayload(id: id, childID: childID,
        startedAt: sleep.startedAt, endedAt: sleep.endedAt, source: "history_import",
        startCondition: sleep.startCondition, sleepLocation: sleep.sleepLocation,
        endCondition: sleep.endCondition))
      return try pendingCommand(id: PendingCommand.ID(rawValue: id.rawValue), familyID: familyID,
        kind: "upsertSleep", payload: payload)
    }
    return try await database.write { database in
      guard let child = try Child.find(childID).fetchOne(database), child.familyID == familyID else { throw SyncError.missingChild }
      var keys: Set<Projection.Key> = []
      for command in commands {
        let key = try Projection.key(for: command)
        let id = SleepSession.ID(rawValue: command.id.rawValue)
        if try SleepSession.find(id).fetchOne(database) != nil
          || PendingCommand.find(command.id).fetchOne(database) != nil
          || AcknowledgedCommand.find(command.id).fetchOne(database) != nil
          || AuthoritativeRecord.find(AuthoritativeRecord.ID(rawValue: "sleepSession:\(id.uuidString)")).fetchOne(database) != nil {
          continue
        }
        try Self.enqueue(command, database: database)
        keys.insert(key)
      }
      try Projection.refresh(familyID: familyID, keys: keys, database: database)
      return keys.count
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
    let pending = try pendingCommand(id: nextID(), familyID: familyID, kind: "upsertGrowthMeasurement", payload: payload)
    let fallbackRevision = existing?.revision
    try await database.write { database in
      try Self.enqueue(pending, reserving: "growthMeasurement", EntityID(rawValue: id.rawValue), fallback: fallbackRevision, database: database)
      try Projection.refresh(familyID: familyID, keys: [Projection.key(for: pending)], database: database)
    }
  }

  public func deleteGrowthMeasurement(
    familyID: Family.ID,
    measurementID: GrowthMeasurement.ID
  ) async throws {
    let existing = try await database.read { database in try GrowthMeasurement.find(measurementID).fetchOne(database) }
    guard let existing else { throw SyncError.missingGrowthMeasurement }
    let payload = try jsonValue(DeleteCommandPayload(id: measurementID))
    let pending = try pendingCommand(id: nextID(), familyID: familyID, kind: "deleteGrowthMeasurement", payload: payload)
    let fallbackRevision = max(1, existing.revision)
    try await database.write { database in
      try Self.enqueue(pending, reserving: "growthMeasurement", EntityID(rawValue: measurementID.rawValue), fallback: fallbackRevision, database: database)
      try Projection.refresh(familyID: familyID, keys: [Projection.key(for: pending)], database: database)
    }
  }

  public func upsertTemperatureReading(
    familyID: Family.ID, childID: Child.ID, readingID: TemperatureReading.ID? = nil,
    measuredAt: Date, centiCelsius: Int, note: String = "", expectedRevision: Int? = nil
  ) async throws {
    guard TemperatureValue.isValid(centiCelsius) else { throw SyncError.invalidTemperatureReading }
    let id = readingID ?? nextID()
    let existing = try await database.read { database in try TemperatureReading.find(id).fetchOne(database) }
    let fallbackRevision = expectedRevision ?? (existing?.revision == 0 ? nil : existing?.revision)
    let payload = try jsonValue(TemperatureReadingCommandPayload(id: id, childID: childID,
      measuredAt: measuredAt, centiCelsius: centiCelsius, note: note))
    let pending = try pendingCommand(id: nextID(), familyID: familyID, kind: "upsertTemperatureReading", payload: payload)
    try await database.write { database in
      try Self.enqueue(pending, reserving: "temperatureReading", EntityID(rawValue: id.rawValue), fallback: fallbackRevision, database: database)
      try Projection.refresh(familyID: familyID, keys: [Projection.key(for: pending)], database: database)
    }
  }

  public func deleteTemperatureReading(familyID: Family.ID, readingID: TemperatureReading.ID,
                                       expectedRevision: Int? = nil) async throws {
    let existing = try await database.read { database in try TemperatureReading.find(readingID).fetchOne(database) }
    guard let existing else { throw SyncError.missingTemperatureReading }
    let fallbackRevision = expectedRevision ?? (existing.revision == 0 ? nil : existing.revision)
    let payload = try jsonValue(DeleteCommandPayload(id: readingID))
    let pending = try pendingCommand(id: nextID(), familyID: familyID, kind: "deleteTemperatureReading", payload: payload)
    try await database.write { database in
      try Self.enqueue(pending, reserving: "temperatureReading", EntityID(rawValue: readingID.rawValue), fallback: fallbackRevision, database: database)
      try Projection.refresh(familyID: familyID, keys: [Projection.key(for: pending)], database: database)
    }
  }

  public func updateGrowthReference(
    familyID: Family.ID,
    childID: Child.ID,
    growthReference: String
  ) async throws {
    let child = try await database.read { database in try Child.find(childID).fetchOne(database) }
    guard let child else { throw SyncError.missingChild }
    try await updateChild(familyID: familyID, childID: childID, nickname: child.nickname,
      birthDate: child.birthDate, predictionMode: child.predictionMode,
      manualIntervalMinutes: child.manualIntervalMinutes,
      quietHoursStartMinutes: child.quietHoursStartMinutes,
      quietHoursEndMinutes: child.quietHoursEndMinutes, timeZone: child.timeZone,
      growthReference: growthReference)
  }

  public func updateChild(
    familyID: Family.ID, childID: Child.ID, nickname: String, birthDate: Date,
    predictionMode: String, manualIntervalMinutes: Int?,
    quietHoursStartMinutes: Int, quietHoursEndMinutes: Int,
    timeZone: String, growthReference: String
  ) async throws {
    guard !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SyncError.invalidChild }
    guard ["none", "girl", "boy"].contains(growthReference) else { throw SyncError.invalidGrowthReference }
    guard ["adaptive", "manual"].contains(predictionMode),
      predictionMode != "manual" || (manualIntervalMinutes ?? 0) > 0 else { throw SyncError.invalidChild }
    guard (0..<1_440).contains(quietHoursStartMinutes), (0..<1_440).contains(quietHoursEndMinutes),
      TimeZone(identifier: timeZone) != nil else { throw SyncError.invalidChild }
    let child = try await database.read { database in try Child.find(childID).fetchOne(database) }
    guard let child, child.familyID == familyID else { throw SyncError.missingChild }
    let payload = try jsonValue(ChildCommandPayload(
      id: child.id, nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
      birthDate: SyncPayload.birthDateFormatter.string(from: birthDate),
      predictionMode: predictionMode, manualIntervalMinutes: manualIntervalMinutes,
      quietHoursStartMinutes: quietHoursStartMinutes,
      quietHoursEndMinutes: quietHoursEndMinutes, timeZone: timeZone,
      growthReference: growthReference
    ))
    let pending = try pendingCommand(id: nextID(), familyID: familyID, kind: "updateChild", payload: payload)
    let fallbackRevision = child.revision == 0 ? nil : child.revision
    try await database.write { database in
      try Self.enqueue(pending, reserving: "child", EntityID(rawValue: childID.rawValue), fallback: fallbackRevision, database: database)
      try Projection.refresh(familyID: familyID, keys: [Projection.key(for: pending)], database: database)
    }
  }

  public func deleteChild(familyID: Family.ID, childID: Child.ID) async throws {
    let child = try await database.read { database in try Child.find(childID).fetchOne(database) }
    guard let child, child.familyID == familyID else { throw SyncError.missingChild }
    let payload = try jsonValue(DeleteCommandPayload(id: childID))
    let pending = try pendingCommand(id: nextID(), familyID: familyID, kind: "deleteChild", payload: payload)
    let fallbackRevision = max(1, child.revision)
    try await database.write { database in
      try Self.enqueue(pending, reserving: "child", EntityID(rawValue: childID.rawValue), fallback: fallbackRevision, database: database)
      try Projection.refresh(familyID: familyID, keys: [Projection.key(for: pending)], database: database)
    }
  }

  /// Reserves the revision that a queued mutation of the same entity will produce,
  /// inside the enqueue transaction so reentrant edits cannot reserve it twice.
  private nonisolated static func pendingRevision(familyID: Family.ID, entityType: String, entityID: EntityID, database: Database) throws -> Int? {
    let commands = try PendingCommand.where { $0.familyID.eq(familyID) }
      .order(by: \.sequence).fetchAll(database)
    for command in commands.reversed() where !command.kind.hasPrefix("delete") {
      let identity = try commandIdentity(command)
      if identity.entityType == entityType && identity.entityID == entityID {
        return (command.expectedRevision ?? 0) + 1
      }
    }
    return nil
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
      try !Self.sendableCommands(familyID: familyID, database: database).isEmpty
    }
    if hasPending {
      return try await synchronize(familyID: familyID)
    }
    return forecast
  }

  /// Pending commands in sequence order, minus those deferred until the family
  /// cursor moves past the point where the server did not have their target.
  private nonisolated static func sendableCommands(familyID: Family.ID, database: Database) throws -> [PendingCommand] {
    let cursor = try SyncState.find(familyID).fetchOne(database)?.cursor ?? 0
    return try PendingCommand
      .where { $0.familyID.eq(familyID) }
      .order(by: \.sequence)
      .fetchAll(database)
      .filter { command in command.deferredAtCursor.map { $0 < cursor } ?? true }
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
        let commands = try Array(Self.sendableCommands(familyID: familyID, database: database).prefix(100))
        return (state?.cursor ?? 0, state?.generation ?? "", commands)
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
          try !Self.sendableCommands(familyID: familyID, database: database).isEmpty
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
      let advancedCursor = response.resetRequired ? response.nextCursor : max(currentCursor, response.nextCursor)
      if let snapshot = response.snapshot {
        try AuthoritativeRecord.where { $0.familyID.eq(familyID) }.delete().execute(database)
        for entity in snapshot.entities {
          let record = AuthoritativeRecord(
            id: AuthoritativeRecord.ID(rawValue: "\(entity.entityType):\(entity.entityID.uuidString)"),
            familyID: familyID,
            entityType: entity.entityType,
            entityID: entity.entityID,
            revision: entity.revision,
            // Snapshots carry tombstones so a replayed create cannot resurrect a deleted entity.
            operation: Self.isTombstone(entity.payload) ? "delete" : "upsert",
            payloadJSON: try JSONEncoder.uneton.encode(entity.payload)
          )
          try AuthoritativeRecord.upsert { record }.execute(database)
        }
      }
      if response.resetRequired {
        // Cursors restart in a restored lineage; a deferral measured against the
        // old one would stall until the new cursor happened to pass it.
        try PendingCommand
          .where { $0.familyID.eq(familyID) }
          .update { $0.deferredAtCursor = #bind(nil) }
          .execute(database)
        let acknowledged = try AcknowledgedCommand
          .where { $0.familyID.eq(familyID) }
          .order(by: \.sequence)
          .fetchAll(database)
        for command in acknowledged {
          try PendingCommand.upsert {
            PendingCommand(
              id: command.id,
              familyID: command.familyID,
              kind: command.kind,
              expectedRevision: command.expectedRevision,
              payloadJSON: command.payloadJSON,
              createdAt: command.createdAt,
              sequence: command.sequence
            )
          }.execute(database)
        }
      }
      // The server maps a duplicate start onto the child's existing active sleep.
      // Later intent for the local session must follow the canonical identity.
      var aliases: [EntityID: SessionAlias] = [:]
      var touched = Set<Projection.Key>()
      for event in response.events {
        touched.insert(Projection.Key(entityType: event.entityType, entityID: event.entityID))
      }
      for result in response.commandResults {
        guard let command = try PendingCommand.find(result.id).fetchOne(database) else { continue }
        let key = try Projection.key(for: command)
        touched.insert(key)
        if let entityID = result.entityID { touched.insert(Projection.Key(entityType: key.entityType, entityID: entityID)) }
        try Self.ingestResultPayload(result, command: command, familyID: familyID, database: database)
        if result.status == "accepted", command.kind == "startSleep",
           let alias = try Self.sessionAlias(result, command: command) {
          aliases[alias.localID] = alias
        }
        if result.status != "accepted",
           let redirected = try Self.redirect(command, aliases: aliases, id: replacementIDs[result.id]!) {
          // Rejected only because it named the local identity in the same batch.
          try PendingCommand.find(result.id).delete().execute(database)
          try Self.enqueue(redirected, database: database)
          continue
        }
        if result.status == "accepted" {
          try AcknowledgedCommand.upsert {
            AcknowledgedCommand(
              id: command.id,
              familyID: command.familyID,
              kind: command.kind,
              expectedRevision: command.expectedRevision,
              payloadJSON: command.payloadJSON,
              createdAt: command.createdAt,
              acknowledgedAt: response.serverTime,
              sequence: command.sequence
            )
          }.execute(database)
          try PendingCommand.find(result.id).delete().execute(database)
        } else if result.payload == nil, Self.targetsExistingEntity(command),
                  response.serverTime.timeIntervalSince(command.deferredSince ?? response.serverTime) < Self.deferralLimit {
          // The server has no such entity yet. After a restore every device replays
          // its own journal, so another device's replay may still create it. Retry
          // once the family cursor moves; give up into a conflict after a day. The
          // server stored this rejection under the command ID, and nothing was
          // applied under it, so the retry needs a new ID in the same position.
          try PendingCommand.find(result.id).delete().execute(database)
          let deferred = PendingCommand(
            id: replacementIDs[result.id]!, familyID: command.familyID, kind: command.kind,
            expectedRevision: command.expectedRevision, payloadJSON: command.payloadJSON,
            createdAt: command.createdAt, lastError: result.error, rebaseAttempt: command.rebaseAttempt,
            sequence: command.sequence, deferredAtCursor: advancedCursor,
            deferredSince: command.deferredSince ?? response.serverTime, deferrals: command.deferrals + 1
          )
          try PendingCommand.insert { deferred }.execute(database)
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
            try Self.enqueue(replacement, database: database)
          case .serverWins:
            break
          case .requiresUser:
            try Self.recordConflict(
              command, serverPayload: try result.payload.map { try JSONEncoder.uneton.encode($0) },
              reason: result.error, at: appliedAt, database: database
            )
          }
        }
      }
      for command in try PendingCommand.where({ $0.familyID.eq(familyID) }).fetchAll(database) {
        guard let since = command.deferredSince,
              response.serverTime.timeIntervalSince(since) >= Self.deferralLimit else { continue }
        try PendingCommand.find(command.id).delete().execute(database)
        touched.insert(try Projection.key(for: command))
        try Self.recordConflict(command, serverPayload: nil, reason: command.lastError, at: appliedAt, database: database)
      }
      if !aliases.isEmpty {
        for pending in try PendingCommand.where({ $0.familyID.eq(familyID) }).fetchAll(database) {
          guard let redirected = try Self.redirect(pending, aliases: aliases, id: pending.id) else { continue }
          try PendingCommand.upsert { redirected }.execute(database)
        }
      }
      // The journal only repairs a database restored behind this device. Entries
      // older than the server's restorable window can never be needed again.
      // A reset response carries no cutoff: its journal is about to be replayed.
      if !response.resetRequired, let cutoff = response.journalRetentionCutoff {
        try AcknowledgedCommand
          .where { $0.familyID.eq(familyID) && $0.acknowledgedAt < cutoff }
          .delete()
          .execute(database)
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
        try Self.ingest(record, database: database)
      }
      let cursor = response.resetRequired ? response.nextCursor : max(currentCursor, response.nextCursor)
      let state = SyncState(id: familyID, cursor: cursor, generation: response.generation, lastSyncedAt: response.serverTime)
      try SyncState.upsert { state }.execute(database)
      if response.snapshot != nil || response.resetRequired {
        try Projection.rebuild(familyID: familyID, database: database)
      } else {
        try Projection.refresh(familyID: familyID, keys: touched, database: database)
      }
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
      guard result.status != "accepted" || result.payload != nil else {
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
    case "createChild", "updateChild", "deleteChild": "child"
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
        try Self.enqueue(replacement, database: database)
      }
      try SyncConflict.find(conflictID).delete().execute(database)
      try Projection.refresh(
        familyID: conflict.familyID,
        keys: [Projection.Key(entityType: conflict.entityType, entityID: conflict.entityID)],
        database: database
      )
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
    try ingest(AuthoritativeRecord(
      id: AuthoritativeRecord.ID(rawValue: "\(identity.entityType):\(entityID.uuidString)"),
      familyID: familyID,
      entityType: identity.entityType,
      entityID: entityID,
      revision: revision,
      operation: result.status == "accepted" && command.kind.hasPrefix("delete") ? "delete" : "upsert",
      payloadJSON: payloadData
    ), database: database)
  }

  static let deferralLimit: TimeInterval = 24 * 3_600

  /// Commands that only make sense against an entity the server already has.
  private nonisolated static func targetsExistingEntity(_ command: PendingCommand) -> Bool {
    switch command.kind {
    case "endSleep", "updateChild", "deleteChild", "deleteSleep", "deleteGrowthMeasurement", "deleteTemperatureReading": true
    case "upsertSleep", "upsertGrowthMeasurement", "upsertTemperatureReading": command.expectedRevision != nil
    default: false
    }
  }

  private nonisolated static func recordConflict(
    _ command: PendingCommand, serverPayload: Data?, reason: String?, at date: Date, database: Database
  ) throws {
    let identity = try commandIdentity(command)
    try SyncConflict.upsert {
      SyncConflict(
        id: SyncConflict.ID(rawValue: command.id.rawValue),
        familyID: command.familyID,
        entityType: identity.entityType,
        entityID: identity.entityID,
        commandKind: command.kind,
        expectedRevision: command.expectedRevision,
        localPayloadJSON: command.payloadJSON,
        serverPayloadJSON: serverPayload,
        reason: reason ?? "The server rejected this change.",
        createdAt: date
      )
    }.execute(database)
  }

  private nonisolated static func isTombstone(_ payload: JSONValue) -> Bool {
    guard case let .object(object) = payload, let deletedAt = object["deletedAt"] else { return false }
    return deletedAt != .null
  }

  private nonisolated static func ingest(_ record: AuthoritativeRecord, database: Database) throws {
    if let existing = try AuthoritativeRecord.find(record.id).fetchOne(database), existing.revision > record.revision {
      return
    }
    try AuthoritativeRecord.upsert { record }.execute(database)
  }

  private nonisolated static func enqueue(
    _ command: PendingCommand,
    reserving entityType: String,
    _ entityID: EntityID,
    fallback: Int?,
    database: Database
  ) throws {
    var command = command
    command.expectedRevision = try pendingRevision(
      familyID: command.familyID, entityType: entityType, entityID: entityID, database: database
    ) ?? fallback
    try enqueue(command, database: database)
  }

  private nonisolated static func enqueue(_ command: PendingCommand, database: Database) throws {
    let pendingSequence = try PendingCommand.order { $0.sequence.desc() }.fetchOne(database)?.sequence ?? 0
    let acknowledgedSequence = try AcknowledgedCommand.order { $0.sequence.desc() }.fetchOne(database)?.sequence ?? 0
    var command = command
    command.sequence = max(pendingSequence, acknowledgedSequence) + 1
    try PendingCommand.insert { command }.execute(database)
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
    case "deleteChild":
      let server = try JSONDecoder.uneton.decode(ServerChildPayload.self, from: serverData)
      guard server.deletedAt == nil else { return .serverWins }
    case "upsertGrowthMeasurement", "deleteGrowthMeasurement", "upsertTemperatureReading", "deleteTemperatureReading", "updateChild":
      break
    case "endSleep":
      let local = try JSONDecoder.uneton.decode(SleepCommandPayload.self, from: command.payloadJSON)
      let server = try JSONDecoder.uneton.decode(ServerSleepPayload.self, from: serverData)
      if server.endedAt == nil, server.deletedAt == nil, server.supersededByID == nil {
        // Still running on the server: another edit only advanced its revision.
        break
      }
      guard let localEnd = local.endedAt, let serverEnd = server.endedAt else { return .requiresUser }
      guard localEnd < serverEnd else { return .serverWins }
      // An end before the server's start is not this session's wake; never send an empty interval.
      guard localEnd > server.startedAt else { return .requiresUser }
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
    return .retry(PendingCommand(
      id: replacementID, familyID: command.familyID, kind: command.kind,
      expectedRevision: serverRevision, payloadJSON: command.payloadJSON,
      createdAt: appliedAt, rebaseAttempt: 1
    ))
  }

  private nonisolated static func sessionAlias(_ result: APICommandResult, command: PendingCommand) throws -> SessionAlias? {
    guard let canonicalID = result.entityID, let payload = result.payload else { return nil }
    let localID = try commandIdentity(command).entityID
    guard canonicalID != localID,
          let canonicalRevision = try revision(JSONEncoder.uneton.encode(payload)) else { return nil }
    // Local intent for the started session reserved revisions from 1.
    return SessionAlias(localID: localID, canonicalID: canonicalID, revisionOffset: canonicalRevision - 1)
  }

  private nonisolated static func redirect(
    _ command: PendingCommand,
    aliases: [EntityID: SessionAlias],
    id: PendingCommand.ID
  ) throws -> PendingCommand? {
    guard !aliases.isEmpty, ["endSleep", "upsertSleep", "deleteSleep"].contains(command.kind),
          let alias = aliases[try commandIdentity(command).entityID] else { return nil }
    let canonicalID = SleepSession.ID(rawValue: alias.canonicalID.rawValue)
    let payloadJSON: Data
    if command.kind == "deleteSleep" {
      payloadJSON = try JSONEncoder.uneton.encode(DeleteCommandPayload(id: canonicalID))
    } else {
      var payload = try JSONDecoder.uneton.decode(SleepCommandPayload.self, from: command.payloadJSON)
      payload.id = canonicalID
      payloadJSON = try JSONEncoder.uneton.encode(payload)
    }
    return PendingCommand(
      id: id, familyID: command.familyID, kind: command.kind,
      expectedRevision: command.expectedRevision.map { $0 + alias.revisionOffset },
      payloadJSON: payloadJSON, createdAt: command.createdAt, lastError: command.lastError,
      rebaseAttempt: command.rebaseAttempt, sequence: command.sequence
    )
  }

  private nonisolated static func commandIdentity(_ command: PendingCommand) throws -> (entityType: String, entityID: EntityID) {
    switch command.kind {
    case "createChild", "updateChild":
      return ("child", try EntityID(rawValue: JSONDecoder.uneton.decode(ChildCommandPayload.self, from: command.payloadJSON).id.rawValue))
    case "deleteChild":
      return ("child", try EntityID(rawValue: JSONDecoder.uneton.decode(DeleteCommandPayload<Child.ID>.self, from: command.payloadJSON).id.rawValue))
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

private struct SessionAlias {
  let localID: EntityID
  let canonicalID: EntityID
  let revisionOffset: Int
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
  case invalidChild
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
  var deletedAt: Date?
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
