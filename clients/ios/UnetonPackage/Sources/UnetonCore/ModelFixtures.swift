#if DEBUG
import Foundation

/// Canonical model construction for previews and tests. Scenario-specific tests can
/// override only the values they care about; new model fields are filled here.
public enum ModelFixtures {
  public static let now = Date(timeIntervalSince1970: 1_790_000_000)
  public static let familyID = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
  public static let childID = UUID(uuidString: "00000000-0000-4000-8000-000000000102")!
  public static let sleepID = UUID(uuidString: "00000000-0000-4000-8000-000000000103")!
  public static let growthID = UUID(uuidString: "00000000-0000-4000-8000-000000000104")!
  public static let authorID = UUID(uuidString: "00000000-0000-4000-8000-000000000105")!
  public static let conflictID = UUID(uuidString: "00000000-0000-4000-8000-000000000106")!
  public static let temperatureID = UUID(uuidString: "00000000-0000-4000-8000-000000000107")!

  public static func family(
    id: UUID = familyID, name: String = "Our family", role: String = "owner",
    updatedAt: Date = now
  ) -> Family {
    Family(id: id, name: name, role: role, updatedAt: updatedAt)
  }

  public static func child(
    id: UUID = childID, familyID: UUID = familyID, nickname: String = "Aino",
    birthDate: Date = now.addingTimeInterval(-180 * 86_400),
    growthReference: String = "none", revision: Int = 1, updatedAt: Date = now
  ) -> Child {
    Child(id: id, familyID: familyID, nickname: nickname, birthDate: birthDate,
      growthReference: growthReference, revision: revision, updatedAt: updatedAt)
  }

  public static func sleep(
    id: UUID = sleepID, familyID: UUID = familyID, childID: UUID = childID,
    startedAt: Date = now.addingTimeInterval(-4 * 3_600),
    endedAt: Date? = now.addingTimeInterval(-2 * 3_600),
    revision: Int = 1, authorID: UUID? = authorID, source: String = "phone",
    updatedAt: Date = now, pendingCommandID: UUID? = nil
  ) -> SleepSession {
    SleepSession(id: id, familyID: familyID, childID: childID,
      startedAt: startedAt, endedAt: endedAt, revision: revision,
      authorID: authorID, source: source, updatedAt: updatedAt,
      pendingCommandID: pendingCommandID)
  }

  public static func growth(
    id: UUID = growthID, familyID: UUID = familyID, childID: UUID = childID,
    measuredAt: Date = now.addingTimeInterval(-86_400), weightGrams: Int? = 6_800,
    heightMillimeters: Int? = 660, note: String = "Neuvola",
    revision: Int = 1, updatedAt: Date = now
  ) -> GrowthMeasurement {
    GrowthMeasurement(id: id, familyID: familyID, childID: childID,
      measuredAt: measuredAt, weightGrams: weightGrams,
      heightMillimeters: heightMillimeters, note: note,
      revision: revision, updatedAt: updatedAt)
  }

  public static func temperature(
    id: UUID = temperatureID, familyID: UUID = familyID, childID: UUID = childID,
    measuredAt: Date = now, centiCelsius: Int = 3_820,
    note: String = "After nap", revision: Int = 1, updatedAt: Date = now,
    pendingCommandID: UUID? = nil
  ) -> TemperatureReading {
    TemperatureReading(id: id, familyID: familyID, childID: childID,
      measuredAt: measuredAt, centiCelsius: centiCelsius,
      note: note, revision: revision, updatedAt: updatedAt,
      pendingCommandID: pendingCommandID)
  }

  public static func conflict(
    localPayloadJSON: Data, serverPayloadJSON: Data?, id: UUID = conflictID,
    familyID: UUID = familyID, entityID: UUID = sleepID,
    expectedRevision: Int? = 1, createdAt: Date = now
  ) -> SyncConflict {
    SyncConflict(id: id, familyID: familyID, entityType: "sleepSession",
      entityID: entityID, commandKind: "upsertSleep",
      expectedRevision: expectedRevision, localPayloadJSON: localPayloadJSON,
      serverPayloadJSON: serverPayloadJSON, reason: "stale revision", createdAt: createdAt)
  }

  public static func watchReading(from reading: TemperatureReading) -> WatchDiaryReading {
    WatchDiaryReading(id: reading.id, measuredAt: reading.measuredAt,
      centiCelsius: reading.centiCelsius, note: reading.note,
      revision: reading.revision, isPending: reading.pendingCommandID != nil)
  }

  public static func watchChild(
    from child: Child, family: Family, activeSleepStartedAt: Date? = nil,
    readings: [TemperatureReading] = []
  ) -> WatchDiaryChild {
    WatchDiaryChild(id: child.id, familyID: family.id, familyName: family.name,
      nickname: child.nickname, activeSleepStartedAt: activeSleepStartedAt,
      readings: readings.map(watchReading))
  }
}
#endif
