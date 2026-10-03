import Foundation
import SQLiteData

enum Projection {
  static func rebuild(familyID: Family.ID, database: Database) throws {
    let records = try AuthoritativeRecord
      .where { $0.familyID.eq(familyID) }
      .fetchAll(database)
    let commands = try PendingCommand
      .where { $0.familyID.eq(familyID) }
      .order(by: \.sequence)
      .fetchAll(database)

    try SleepSession.where { $0.familyID.eq(familyID) }.delete().execute(database)
    try GrowthMeasurement.where { $0.familyID.eq(familyID) }.delete().execute(database)
    try TemperatureReading.where { $0.familyID.eq(familyID) }.delete().execute(database)
    try Child.where { $0.familyID.eq(familyID) }.delete().execute(database)

    for record in records where record.operation != "delete" && record.entityType == "child" {
      try applyAuthoritative(record, familyID: familyID, database: database)
    }
    for record in records where record.operation != "delete" && record.entityType == "sleepSession" {
      let payload = try JSONDecoder.uneton.decode(ServerSleepPayload.self, from: record.payloadJSON)
      guard try Child.find(payload.childID).fetchOne(database) != nil else { continue }
      try applyAuthoritative(record, familyID: familyID, database: database)
    }
    for record in records where record.operation != "delete" && record.entityType == "growthMeasurement" {
      let payload = try JSONDecoder.uneton.decode(ServerGrowthMeasurementPayload.self, from: record.payloadJSON)
      guard try Child.find(payload.childID).fetchOne(database) != nil else { continue }
      try applyAuthoritative(record, familyID: familyID, database: database)
    }
    for record in records where record.operation != "delete" && record.entityType == "temperatureReading" {
      let payload = try JSONDecoder.uneton.decode(ServerTemperatureReadingPayload.self, from: record.payloadJSON)
      guard try Child.find(payload.childID).fetchOne(database) != nil else { continue }
      try applyAuthoritative(record, familyID: familyID, database: database)
    }
    for command in commands {
      try applyPending(command, database: database)
    }
  }

  struct Key: Hashable, Sendable {
    var entityType: String
    var entityID: EntityID
  }

  /// Re-materializes only the given entities. A full rebuild rewrites every row of
  /// the family, which grows with years of history; one tap touches one entity.
  /// The result is identical to `rebuild`: child changes, which can hide or reveal
  /// a whole diary, fall back to a full rebuild.
  /// Tests and simulations set this to prove every refresh equals a full rebuild.
  nonisolated(unsafe) public static var verifiesIncrementalRefresh = false

  static func refresh(familyID: Family.ID, keys: Set<Key>, database: Database) throws {
    try refreshIncrementally(familyID: familyID, keys: keys, database: database)
    guard verifiesIncrementalRefresh else { return }
    let incremental = try rows(familyID: familyID, database: database)
    try rebuild(familyID: familyID, database: database)
    let full = try rows(familyID: familyID, database: database)
    guard incremental == full else {
      throw ProjectionMismatch(description: "incremental refresh of \(keys) differs from a full rebuild:\nincremental \(incremental)\nfull \(full)")
    }
  }

  struct ProjectionMismatch: Error, CustomStringConvertible { var description: String }

  private struct Rows: Equatable {
    var children: [Child]
    var sleeps: [SleepSession]
    var growth: [GrowthMeasurement]
    var temperatures: [TemperatureReading]
  }

  private static func rows(familyID: Family.ID, database: Database) throws -> Rows {
    Rows(
      children: try Child.where { $0.familyID.eq(familyID) }.order(by: \.id).fetchAll(database),
      sleeps: try SleepSession.where { $0.familyID.eq(familyID) }.order(by: \.id).fetchAll(database),
      growth: try GrowthMeasurement.where { $0.familyID.eq(familyID) }.order(by: \.id).fetchAll(database),
      temperatures: try TemperatureReading.where { $0.familyID.eq(familyID) }.order(by: \.id).fetchAll(database)
    )
  }

  private static func refreshIncrementally(familyID: Family.ID, keys: Set<Key>, database: Database) throws {
    guard !keys.isEmpty else { return }
    let commands = try PendingCommand
      .where { $0.familyID.eq(familyID) }
      .order(by: \.sequence)
      .fetchAll(database)
    let childCommandKinds: Set<String> = ["createChild", "updateChild", "deleteChild"]
    if keys.contains(where: { $0.entityType == "child" }) || commands.contains(where: { childCommandKinds.contains($0.kind) }) {
      return try rebuild(familyID: familyID, database: database)
    }
    for key in keys {
      switch key.entityType {
      case "sleepSession":
        try SleepSession.where { $0.familyID.eq(familyID) && $0.id.eq(SleepSession.ID(rawValue: key.entityID.rawValue)) }.delete().execute(database)
      case "growthMeasurement":
        try GrowthMeasurement.where { $0.familyID.eq(familyID) && $0.id.eq(GrowthMeasurement.ID(rawValue: key.entityID.rawValue)) }.delete().execute(database)
      case "temperatureReading":
        try TemperatureReading.where { $0.familyID.eq(familyID) && $0.id.eq(TemperatureReading.ID(rawValue: key.entityID.rawValue)) }.delete().execute(database)
      default:
        return try rebuild(familyID: familyID, database: database)
      }
    }
    // With no pending child commands the projected children equal the
    // authoritative ones, so this matches the full rebuild's child check.
    for key in keys {
      let recordID = AuthoritativeRecord.ID(rawValue: "\(key.entityType):\(key.entityID.uuidString)")
      guard let record = try AuthoritativeRecord.find(recordID).fetchOne(database),
            record.familyID == familyID, record.operation != "delete"
      else { continue }
      let childID: Child.ID = switch key.entityType {
      case "sleepSession": try JSONDecoder.uneton.decode(ServerSleepPayload.self, from: record.payloadJSON).childID
      case "growthMeasurement": try JSONDecoder.uneton.decode(ServerGrowthMeasurementPayload.self, from: record.payloadJSON).childID
      default: try JSONDecoder.uneton.decode(ServerTemperatureReadingPayload.self, from: record.payloadJSON).childID
      }
      guard try Child.find(childID).fetchOne(database) != nil else { continue }
      try applyAuthoritative(record, familyID: familyID, database: database)
    }
    for command in commands {
      guard keys.contains(try key(for: command)) else { continue }
      try applyPending(command, database: database)
    }
  }

  static func key(for command: PendingCommand) throws -> Key {
    let decoder = JSONDecoder.uneton
    struct Identity: Decodable { var id: UUID }
    let id = try decoder.decode(Identity.self, from: command.payloadJSON).id
    let entityType = switch command.kind {
    case "createChild", "updateChild", "deleteChild": "child"
    case "startSleep", "endSleep", "upsertSleep", "deleteSleep": "sleepSession"
    case "upsertGrowthMeasurement", "deleteGrowthMeasurement": "growthMeasurement"
    case "upsertTemperatureReading", "deleteTemperatureReading": "temperatureReading"
    default: "unknown"
    }
    return Key(entityType: entityType, entityID: EntityID(rawValue: id))
  }

  static func applyAuthoritative(
    _ record: AuthoritativeRecord,
    familyID: Family.ID,
    database: Database
  ) throws {
    switch record.entityType {
    case "child":
      let payload = try JSONDecoder.uneton.decode(ServerChildPayload.self, from: record.payloadJSON)
      guard payload.deletedAt == nil else { return }
      guard let birthDate = SyncPayload.birthDateFormatter.date(from: payload.birthDate) else {
        throw SyncError.invalidServerPayload
      }
      try Child.upsert {
        Child(
          id: payload.id,
          familyID: familyID,
          nickname: payload.nickname,
          birthDate: birthDate,
          predictionMode: payload.predictionMode,
          manualIntervalMinutes: payload.manualIntervalMinutes,
          quietHoursStartMinutes: payload.quietHoursStartMinutes,
          quietHoursEndMinutes: payload.quietHoursEndMinutes,
          timeZone: payload.timeZone,
          growthReference: payload.growthReference,
          revision: payload.revision,
          updatedAt: payload.updatedAt
        )
      }.execute(database)
    case "sleepSession":
      let payload = try JSONDecoder.uneton.decode(ServerSleepPayload.self, from: record.payloadJSON)
      try SleepSession.upsert {
        SleepSession(
          id: payload.id,
          familyID: payload.familyID,
          childID: payload.childID,
          startedAt: payload.startedAt,
          endedAt: payload.endedAt,
          revision: payload.revision,
          authorID: payload.authorID,
          source: payload.source,
          startCondition: payload.startCondition,
          sleepLocation: payload.sleepLocation,
          endCondition: payload.endCondition,
          wakeMood: payload.wakeMood,
          wakeReason: payload.wakeReason,
          caregiverIntervened: payload.caregiverIntervened,
          supersededByID: payload.supersededByID,
          updatedAt: payload.updatedAt,
          deletedAt: payload.deletedAt
        )
      }.execute(database)
    case "growthMeasurement":
      let payload = try JSONDecoder.uneton.decode(ServerGrowthMeasurementPayload.self, from: record.payloadJSON)
      try GrowthMeasurement.upsert {
        GrowthMeasurement(
          id: payload.id, familyID: payload.familyID, childID: payload.childID,
          measuredAt: payload.measuredAt, weightGrams: payload.weightGrams,
          heightMillimeters: payload.heightMillimeters, note: payload.note,
          revision: payload.revision, updatedAt: payload.updatedAt, deletedAt: payload.deletedAt
        )
      }.execute(database)
    case "temperatureReading":
      let payload = try JSONDecoder.uneton.decode(ServerTemperatureReadingPayload.self, from: record.payloadJSON)
      try TemperatureReading.upsert {
        TemperatureReading(id: payload.id, familyID: payload.familyID, childID: payload.childID,
          measuredAt: payload.measuredAt, centiCelsius: payload.centiCelsius,
          note: payload.note, revision: payload.revision, updatedAt: payload.updatedAt,
          deletedAt: payload.deletedAt)
      }.execute(database)
    default:
      break
    }
  }

  static func applyPending(_ command: PendingCommand, database: Database) throws {
    switch command.kind {
    case "createChild", "updateChild":
      let payload = try JSONDecoder.uneton.decode(ChildCommandPayload.self, from: command.payloadJSON)
      let current = try Child.find(payload.id).fetchOne(database)
      guard let birthDate = SyncPayload.birthDateFormatter.date(from: payload.birthDate) ?? current?.birthDate else {
        throw SyncError.invalidServerPayload
      }
      try Child.upsert {
        Child(
          id: payload.id,
          familyID: command.familyID,
          nickname: payload.nickname.isEmpty ? current?.nickname ?? "" : payload.nickname,
          birthDate: birthDate,
          predictionMode: payload.predictionMode.isEmpty ? current?.predictionMode ?? "adaptive" : payload.predictionMode,
          manualIntervalMinutes: payload.manualIntervalMinutes,
          quietHoursStartMinutes: payload.quietHoursStartMinutes,
          quietHoursEndMinutes: payload.quietHoursEndMinutes,
          timeZone: payload.timeZone.isEmpty ? current?.timeZone ?? TimeZone.current.identifier : payload.timeZone,
          growthReference: payload.growthReference.isEmpty ? current?.growthReference ?? "none" : payload.growthReference,
          revision: current?.revision ?? 0,
          updatedAt: command.createdAt
        )
      }.execute(database)
    case "deleteChild":
      let payload = try JSONDecoder.uneton.decode(DeleteCommandPayload<Child.ID>.self, from: command.payloadJSON)
      try Child.find(payload.id).delete().execute(database)
    case "startSleep", "upsertSleep", "endSleep":
      let payload = try JSONDecoder.uneton.decode(SleepCommandPayload.self, from: command.payloadJSON)
      guard try Child.find(payload.childID).fetchOne(database) != nil else { return }
      var session = try SleepSession.find(payload.id).fetchOne(database) ?? {
        return SleepSession(
          id: payload.id,
          familyID: command.familyID,
          childID: payload.childID,
          startedAt: payload.startedAt,
          source: payload.source,
          updatedAt: command.createdAt
        )
      }()
      session.startedAt = payload.startedAt
      session.childID = payload.childID
      session.endedAt = payload.endedAt
      session.source = payload.source.isEmpty ? session.source : payload.source
      session.startCondition = payload.startCondition
      session.sleepLocation = payload.sleepLocation
      session.endCondition = payload.endCondition
      session.wakeMood = payload.wakeMood
      session.wakeReason = payload.wakeReason
      session.caregiverIntervened = payload.caregiverIntervened
      session.updatedAt = command.createdAt
      session.pendingCommandID = command.id
      try SleepSession.upsert { session }.execute(database)
    case "deleteSleep":
      let payload = try JSONDecoder.uneton.decode(DeleteCommandPayload<SleepSession.ID>.self, from: command.payloadJSON)
      try SleepSession.find(payload.id).delete().execute(database)
    case "upsertGrowthMeasurement":
      let payload = try JSONDecoder.uneton.decode(GrowthMeasurementCommandPayload.self, from: command.payloadJSON)
      guard try Child.find(payload.childID).fetchOne(database) != nil else { return }
      let current = try GrowthMeasurement.find(payload.id).fetchOne(database)
      try GrowthMeasurement.upsert {
        GrowthMeasurement(
          id: payload.id, familyID: command.familyID, childID: payload.childID,
          measuredAt: payload.measuredAt, weightGrams: payload.weightGrams,
          heightMillimeters: payload.heightMillimeters, note: payload.note,
          revision: current?.revision ?? 0, updatedAt: command.createdAt,
          pendingCommandID: command.id
        )
      }.execute(database)
    case "deleteGrowthMeasurement":
      let payload = try JSONDecoder.uneton.decode(DeleteCommandPayload<GrowthMeasurement.ID>.self, from: command.payloadJSON)
      try GrowthMeasurement.find(payload.id).delete().execute(database)
    case "upsertTemperatureReading":
      let payload = try JSONDecoder.uneton.decode(TemperatureReadingCommandPayload.self, from: command.payloadJSON)
      guard try Child.find(payload.childID).fetchOne(database) != nil else { return }
      let current = try TemperatureReading.find(payload.id).fetchOne(database)
      try TemperatureReading.upsert {
        TemperatureReading(id: payload.id, familyID: command.familyID, childID: payload.childID,
          measuredAt: payload.measuredAt, centiCelsius: payload.centiCelsius, note: payload.note,
          revision: current?.revision ?? 0, updatedAt: command.createdAt, pendingCommandID: command.id)
      }.execute(database)
    case "deleteTemperatureReading":
      let payload = try JSONDecoder.uneton.decode(DeleteCommandPayload<TemperatureReading.ID>.self, from: command.payloadJSON)
      try TemperatureReading.find(payload.id).delete().execute(database)
    default:
      break
    }
  }
}

enum SyncPayload {
  static let birthDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}
