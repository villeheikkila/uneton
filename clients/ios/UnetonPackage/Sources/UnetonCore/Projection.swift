import Foundation
import SQLiteData

enum Projection {
  static func rebuild(familyID: Family.ID, database: Database) throws {
    let records = try AuthoritativeRecord
      .where { $0.familyID.eq(familyID) }
      .fetchAll(database)
    let commands = try PendingCommand
      .where { $0.familyID.eq(familyID) }
      .fetchAll(database)
      .sorted {
        ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
      }

    try SleepSession.where { $0.familyID.eq(familyID) }.delete().execute(database)
    try Child.where { $0.familyID.eq(familyID) }.delete().execute(database)

    for record in records where record.operation != "delete" && record.entityType == "child" {
      try applyAuthoritative(record, familyID: familyID, database: database)
    }
    for record in records where record.operation != "delete" && record.entityType == "sleepSession" {
      try applyAuthoritative(record, familyID: familyID, database: database)
    }
    for command in commands {
      try applyPending(command, database: database)
    }
  }

  static func applyAuthoritative(
    _ record: AuthoritativeRecord,
    familyID: Family.ID,
    database: Database
  ) throws {
    switch record.entityType {
    case "child":
      let payload = try JSONDecoder.uneton.decode(ServerChildPayload.self, from: record.payloadJSON)
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
    default:
      break
    }
  }

  static func applyPending(_ command: PendingCommand, database: Database) throws {
    switch command.kind {
    case "createChild", "updateChild", "updatePredictionSettings":
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
          quietHoursStartMinutes: payload.quietHoursStartMinutes > 0 ? payload.quietHoursStartMinutes : current?.quietHoursStartMinutes ?? 1_200,
          quietHoursEndMinutes: payload.quietHoursEndMinutes > 0 ? payload.quietHoursEndMinutes : current?.quietHoursEndMinutes ?? 360,
          timeZone: payload.timeZone.isEmpty ? current?.timeZone ?? TimeZone.current.identifier : payload.timeZone,
          revision: current?.revision ?? 0,
          updatedAt: command.createdAt
        )
      }.execute(database)
    case "startSleep", "upsertSleep", "endSleep":
      let payload = try JSONDecoder.uneton.decode(SleepCommandPayload.self, from: command.payloadJSON)
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
      let payload = try JSONDecoder.uneton.decode(DeleteCommandPayload.self, from: command.payloadJSON)
      try SleepSession.find(payload.id).delete().execute(database)
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
