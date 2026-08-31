import Dependencies
import Foundation
import SQLiteData

@Table
public struct Family: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var role: String
  public var updatedAt: Date

  public init(id: UUID, name: String, role: String, updatedAt: Date) {
    self.id = id
    self.name = name
    self.role = role
    self.updatedAt = updatedAt
  }
}

@Table
public struct FamilyMember: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var familyID: Family.ID
  public var displayName: String
  public var role: String
  public var joinedAt: Date

  public init(id: UUID, familyID: Family.ID, displayName: String, role: String, joinedAt: Date) {
    self.id = id
    self.familyID = familyID
    self.displayName = displayName
    self.role = role
    self.joinedAt = joinedAt
  }
}

@Table("children")
public struct Child: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var familyID: Family.ID
  public var nickname: String
  public var birthDate: Date
  public var predictionMode: String
  public var manualIntervalMinutes: Int?
  public var quietHoursStartMinutes: Int
  public var quietHoursEndMinutes: Int
  public var timeZone: String
  public var growthReference: String
  public var revision: Int
  public var updatedAt: Date

  public init(
    id: UUID,
    familyID: Family.ID,
    nickname: String,
    birthDate: Date,
    predictionMode: String = "adaptive",
    manualIntervalMinutes: Int? = nil,
    quietHoursStartMinutes: Int = 1_200,
    quietHoursEndMinutes: Int = 360,
    timeZone: String = TimeZone.current.identifier,
    growthReference: String = "none",
    revision: Int = 0,
    updatedAt: Date
  ) {
    self.id = id
    self.familyID = familyID
    self.nickname = nickname
    self.birthDate = birthDate
    self.predictionMode = predictionMode
    self.manualIntervalMinutes = manualIntervalMinutes
    self.quietHoursStartMinutes = quietHoursStartMinutes
    self.quietHoursEndMinutes = quietHoursEndMinutes
    self.timeZone = timeZone
    self.growthReference = growthReference
    self.revision = revision
    self.updatedAt = updatedAt
  }
}

@Table
public struct SleepSession: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var familyID: Family.ID
  public var childID: Child.ID
  public var startedAt: Date
  public var endedAt: Date?
  public var revision: Int
  public var authorID: UUID?
  public var source: String
  public var startCondition: String
  public var sleepLocation: String
  public var endCondition: String
  public var wakeMood: String
  public var wakeReason: String
  public var caregiverIntervened: Bool?
  public var supersededByID: SleepSession.ID?
  public var updatedAt: Date
  public var deletedAt: Date?
  public var pendingCommandID: UUID?

  public init(
    id: UUID,
    familyID: Family.ID,
    childID: Child.ID,
    startedAt: Date,
    endedAt: Date? = nil,
    revision: Int = 0,
    authorID: UUID? = nil,
    source: String = "phone",
    startCondition: String = "",
    sleepLocation: String = "",
    endCondition: String = "",
    wakeMood: String = "unknown",
    wakeReason: String = "unknown",
    caregiverIntervened: Bool? = nil,
    supersededByID: SleepSession.ID? = nil,
    updatedAt: Date,
    deletedAt: Date? = nil,
    pendingCommandID: UUID? = nil
  ) {
    self.id = id
    self.familyID = familyID
    self.childID = childID
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.revision = revision
    self.authorID = authorID
    self.source = source
    self.startCondition = startCondition
    self.sleepLocation = sleepLocation
    self.endCondition = endCondition
    self.wakeMood = wakeMood
    self.wakeReason = wakeReason
    self.caregiverIntervened = caregiverIntervened
    self.supersededByID = supersededByID
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
    self.pendingCommandID = pendingCommandID
  }
}

@Table
public struct GrowthMeasurement: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var familyID: Family.ID
  public var childID: Child.ID
  public var measuredAt: Date
  public var weightGrams: Int?
  public var heightMillimeters: Int?
  public var note: String
  public var revision: Int
  public var updatedAt: Date
  public var deletedAt: Date?
  public var pendingCommandID: UUID?

  public init(id: UUID, familyID: Family.ID, childID: Child.ID, measuredAt: Date, weightGrams: Int? = nil, heightMillimeters: Int? = nil, note: String = "", revision: Int = 0, updatedAt: Date, deletedAt: Date? = nil, pendingCommandID: UUID? = nil) {
    self.id = id
    self.familyID = familyID
    self.childID = childID
    self.measuredAt = measuredAt
    self.weightGrams = weightGrams
    self.heightMillimeters = heightMillimeters
    self.note = note
    self.revision = revision
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
    self.pendingCommandID = pendingCommandID
  }
}

@Table("growthReferencePoints")
public struct GrowthReferencePoint: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public var reference: String
  public var metric: String
  public var ageMonths: Int
  public var sd: Int
  public var value: Int

  public init(reference: String, metric: String, ageMonths: Int, sd: Int, value: Int) {
    self.id = "\(reference):\(metric):\(ageMonths):\(sd)"
    self.reference = reference
    self.metric = metric
    self.ageMonths = ageMonths
    self.sd = sd
    self.value = value
  }
}

@Table
public struct AuthoritativeRecord: Identifiable, Equatable, Sendable {
  public let id: String
  public var familyID: Family.ID
  public var entityType: String
  public var entityID: UUID
  public var revision: Int
  public var operation: String
  public var payloadJSON: Data

  public init(id: String, familyID: Family.ID, entityType: String, entityID: UUID, revision: Int, operation: String, payloadJSON: Data) {
    self.id = id
    self.familyID = familyID
    self.entityType = entityType
    self.entityID = entityID
    self.revision = revision
    self.operation = operation
    self.payloadJSON = payloadJSON
  }
}

@Table
public struct PendingCommand: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var familyID: Family.ID
  public var kind: String
  public var expectedRevision: Int?
  public var payloadJSON: Data
  public var createdAt: Date
  public var lastError: String?
  public var rebaseAttempt: Int

  public init(id: UUID, familyID: Family.ID, kind: String, expectedRevision: Int? = nil, payloadJSON: Data, createdAt: Date, lastError: String? = nil, rebaseAttempt: Int = 0) {
    self.id = id
    self.familyID = familyID
    self.kind = kind
    self.expectedRevision = expectedRevision
    self.payloadJSON = payloadJSON
    self.createdAt = createdAt
    self.lastError = lastError
    self.rebaseAttempt = rebaseAttempt
  }
}

@Table
public struct AcknowledgedCommand: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var familyID: Family.ID
  public var kind: String
  public var expectedRevision: Int?
  public var payloadJSON: Data
  public var createdAt: Date
  public var acknowledgedAt: Date

  public init(id: UUID, familyID: Family.ID, kind: String, expectedRevision: Int? = nil, payloadJSON: Data, createdAt: Date, acknowledgedAt: Date) {
    self.id = id
    self.familyID = familyID
    self.kind = kind
    self.expectedRevision = expectedRevision
    self.payloadJSON = payloadJSON
    self.createdAt = createdAt
    self.acknowledgedAt = acknowledgedAt
  }
}

@Table
public struct SyncState: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var cursor: Int64
  public var generation: String
  public var lastSyncedAt: Date?

  public init(id: UUID, cursor: Int64 = 0, generation: String = "", lastSyncedAt: Date? = nil) {
    self.id = id
    self.cursor = cursor
    self.generation = generation
    self.lastSyncedAt = lastSyncedAt
  }
}

@Table
public struct SyncConflict: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var familyID: Family.ID
  public var entityType: String
  public var entityID: UUID
  public var commandKind: String
  public var expectedRevision: Int?
  public var localPayloadJSON: Data
  public var serverPayloadJSON: Data?
  public var reason: String
  public var createdAt: Date

  public init(
    id: UUID,
    familyID: Family.ID,
    entityType: String,
    entityID: UUID,
    commandKind: String,
    expectedRevision: Int? = nil,
    localPayloadJSON: Data,
    serverPayloadJSON: Data? = nil,
    reason: String,
    createdAt: Date
  ) {
    self.id = id
    self.familyID = familyID
    self.entityType = entityType
    self.entityID = entityID
    self.commandKind = commandKind
    self.expectedRevision = expectedRevision
    self.localPayloadJSON = localPayloadJSON
    self.serverPayloadJSON = serverPayloadJSON
    self.reason = reason
    self.createdAt = createdAt
  }
}

@DatabaseFunction
nonisolated func uuid() -> UUID {
  @Dependency(\.uuid) var uuid
  return uuid()
}

extension DependencyValues {
  public mutating func bootstrapDatabase() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { database in
      database.add(function: $uuid)
    }
    let database = try SQLiteData.defaultDatabase(configuration: configuration)
    var migrator = DatabaseMigrator()
    #if DEBUG
      migrator.eraseDatabaseOnSchemaChange = true
    #endif
    migrator.registerMigration("Create initial Uneton schema") { database in
      try #sql("""
        CREATE TABLE "families" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL DEFAULT '',
          "role" TEXT NOT NULL DEFAULT 'caregiver',
          "updatedAt" TEXT NOT NULL
        ) STRICT
        """).execute(database)
      try #sql("""
        CREATE TABLE "familyMembers" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "familyID" TEXT NOT NULL REFERENCES "families"("id") ON DELETE CASCADE,
          "displayName" TEXT NOT NULL DEFAULT '',
          "role" TEXT NOT NULL DEFAULT 'caregiver',
          "joinedAt" TEXT NOT NULL
        ) STRICT
        """).execute(database)
      try #sql("""
        CREATE INDEX "index_familyMembers_on_familyID" ON "familyMembers"("familyID")
        """).execute(database)
      try #sql("""
        CREATE TABLE "children" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "familyID" TEXT NOT NULL REFERENCES "families"("id") ON DELETE CASCADE,
          "nickname" TEXT NOT NULL DEFAULT '',
          "birthDate" TEXT NOT NULL,
          "predictionMode" TEXT NOT NULL DEFAULT 'adaptive',
          "manualIntervalMinutes" INTEGER,
          "quietHoursStartMinutes" INTEGER NOT NULL DEFAULT 1200,
          "quietHoursEndMinutes" INTEGER NOT NULL DEFAULT 360,
          "timeZone" TEXT NOT NULL DEFAULT 'Europe/Helsinki',
          "growthReference" TEXT NOT NULL DEFAULT 'none',
          "revision" INTEGER NOT NULL DEFAULT 0,
          "updatedAt" TEXT NOT NULL
        ) STRICT
        """).execute(database)
      try #sql("""
        CREATE INDEX "index_children_on_familyID" ON "children"("familyID")
        """).execute(database)
      try #sql("""
        CREATE TABLE "sleepSessions" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "familyID" TEXT NOT NULL REFERENCES "families"("id") ON DELETE CASCADE,
          "childID" TEXT NOT NULL REFERENCES "children"("id") ON DELETE CASCADE,
          "startedAt" TEXT NOT NULL,
          "endedAt" TEXT,
          "revision" INTEGER NOT NULL DEFAULT 0,
          "authorID" TEXT,
          "source" TEXT NOT NULL DEFAULT 'phone',
          "startCondition" TEXT NOT NULL DEFAULT '',
          "sleepLocation" TEXT NOT NULL DEFAULT '',
          "endCondition" TEXT NOT NULL DEFAULT '',
          "wakeMood" TEXT NOT NULL DEFAULT 'unknown',
          "wakeReason" TEXT NOT NULL DEFAULT 'unknown',
          "caregiverIntervened" INTEGER,
          "supersededByID" TEXT,
          "updatedAt" TEXT NOT NULL,
          "deletedAt" TEXT,
          "pendingCommandID" TEXT
        ) STRICT
        """).execute(database)
      try #sql("""
        CREATE INDEX "index_sleepSessions_on_childID_startedAt"
        ON "sleepSessions"("childID", "startedAt" DESC)
        """).execute(database)
      try #sql("""
        CREATE TABLE "growthMeasurements" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "familyID" TEXT NOT NULL REFERENCES "families"("id") ON DELETE CASCADE,
          "childID" TEXT NOT NULL REFERENCES "children"("id") ON DELETE CASCADE,
          "measuredAt" TEXT NOT NULL,
          "weightGrams" INTEGER,
          "heightMillimeters" INTEGER,
          "note" TEXT NOT NULL DEFAULT '',
          "revision" INTEGER NOT NULL DEFAULT 0,
          "updatedAt" TEXT NOT NULL,
          "deletedAt" TEXT,
          "pendingCommandID" TEXT
        ) STRICT
        """).execute(database)
      try #sql("""
        CREATE INDEX "index_growthMeasurements_on_childID_measuredAt"
        ON "growthMeasurements"("childID", "measuredAt" DESC)
        """).execute(database)
      try #sql("""
        CREATE TABLE IF NOT EXISTS "growthReferencePoints" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "reference" TEXT NOT NULL,
          "metric" TEXT NOT NULL,
          "ageMonths" INTEGER NOT NULL,
          "sd" INTEGER NOT NULL,
          "value" INTEGER NOT NULL
        ) STRICT
        """).execute(database)
      try #sql("""
        CREATE TABLE "authoritativeRecords" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "familyID" TEXT NOT NULL,
          "entityType" TEXT NOT NULL,
          "entityID" TEXT NOT NULL,
          "revision" INTEGER NOT NULL,
          "operation" TEXT NOT NULL,
          "payloadJSON" BLOB NOT NULL
        ) STRICT
        """).execute(database)
      try #sql("""
        CREATE TABLE "pendingCommands" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "familyID" TEXT NOT NULL,
          "kind" TEXT NOT NULL,
          "expectedRevision" INTEGER,
          "payloadJSON" BLOB NOT NULL,
          "createdAt" TEXT NOT NULL,
          "lastError" TEXT
        ) STRICT
        """).execute(database)
      try #sql("""
        CREATE INDEX "index_pendingCommands_on_familyID_createdAt"
        ON "pendingCommands"("familyID", "createdAt")
        """).execute(database)
      try #sql("""
        CREATE TABLE "syncStates" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "cursor" INTEGER NOT NULL DEFAULT 0,
          "lastSyncedAt" TEXT
        ) STRICT
        """).execute(database)
    }
    migrator.registerMigration("Add terminal sync conflicts") { database in
      try #sql("""
        CREATE TABLE "syncConflicts" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "familyID" TEXT NOT NULL,
          "entityType" TEXT NOT NULL,
          "entityID" TEXT NOT NULL,
          "commandKind" TEXT NOT NULL,
          "expectedRevision" INTEGER,
          "localPayloadJSON" BLOB NOT NULL,
          "serverPayloadJSON" BLOB,
          "reason" TEXT NOT NULL,
          "createdAt" TEXT NOT NULL
        ) STRICT
        """).execute(database)
      try #sql("""
        CREATE INDEX "index_syncConflicts_on_familyID_createdAt"
        ON "syncConflicts"("familyID", "createdAt")
        """).execute(database)
    }
    migrator.registerMigration("Track command rebase attempts") { database in
      try #sql("""
        ALTER TABLE "pendingCommands"
        ADD COLUMN "rebaseAttempt" INTEGER NOT NULL DEFAULT 0
        """).execute(database)
    }
    migrator.registerMigration("Cache growth reference bootstrap") { database in
      try #sql("""
        CREATE TABLE IF NOT EXISTS "growthReferencePoints" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "reference" TEXT NOT NULL,
          "metric" TEXT NOT NULL,
          "ageMonths" INTEGER NOT NULL,
          "sd" INTEGER NOT NULL,
          "value" INTEGER NOT NULL
        ) STRICT
        """).execute(database)
    }
    migrator.registerMigration("Add snapshot recovery journal") { database in
      try #sql("""
        ALTER TABLE "syncStates"
        ADD COLUMN "generation" TEXT NOT NULL DEFAULT ''
        """).execute(database)
      try #sql("""
        CREATE TABLE "acknowledgedCommands" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "familyID" TEXT NOT NULL,
          "kind" TEXT NOT NULL,
          "expectedRevision" INTEGER,
          "payloadJSON" BLOB NOT NULL,
          "createdAt" TEXT NOT NULL,
          "acknowledgedAt" TEXT NOT NULL
        ) STRICT
        """).execute(database)
      try #sql("""
        CREATE INDEX "index_acknowledgedCommands_on_familyID_acknowledgedAt"
        ON "acknowledgedCommands"("familyID", "acknowledgedAt")
        """).execute(database)
    }
    try migrator.migrate(database)
    defaultDatabase = database
  }
}
