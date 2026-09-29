import Foundation
import Testing
@testable import UnetonCore

struct WatchDiaryTests {
  @Test func temperatureValueUsesTheSameUnitsOnPhoneAndWatch() {
    #expect(TemperatureValue.centiCelsius(from: "38,75") == 3875)
    #expect(TemperatureValue.centiCelsius(from: " 38.7 ") == 3870)
    #expect(TemperatureValue.centiCelsius(from: "not a reading") == nil)
    #expect(TemperatureValue.centiCelsius(from: "51") == nil)
  }

  @Test func watchRequestsRequireAChildAndRevisionForEdits() {
    let familyID = Family.ID()
    let childID = Child.ID()
    let sessionID = SleepSession.ID()
    let readingID = TemperatureReading.ID()
    #expect(WatchDiaryRequest(action: .status).isWellFormed)
    #expect(!WatchDiaryRequest(action: .startSleep).isWellFormed)
    #expect(!WatchDiaryRequest(action: .startSleep, familyID: familyID, childID: childID).isWellFormed)
    #expect(WatchDiaryRequest(action: .startSleep, familyID: familyID, childID: childID, sessionID: sessionID).isWellFormed)
    #expect(!WatchDiaryRequest(action: .endSleep, familyID: familyID, childID: childID).isWellFormed)
    #expect(WatchDiaryRequest(action: .endSleep, familyID: familyID, childID: childID, sessionID: sessionID).isWellFormed)
    #expect(WatchDiaryRequest(action: .upsertTemperature, familyID: familyID, childID: childID,
      readingID: readingID, isNewReading: true, measuredAt: .now, centiCelsius: 3875).isWellFormed)
    #expect(!WatchDiaryRequest(action: .upsertTemperature, familyID: familyID, childID: childID,
      readingID: readingID, measuredAt: .now, centiCelsius: 3875).isWellFormed)
    #expect(WatchDiaryRequest(action: .deleteTemperature, familyID: familyID, childID: childID,
      readingID: readingID, expectedRevision: 2).isWellFormed)
  }

  @Test func retryPreservesTheTemperatureReadingIdentity() throws {
    let request = WatchDiaryRequest(action: .upsertTemperature, familyID: Family.ID(), childID: Child.ID(),
      readingID: TemperatureReading.ID(), isNewReading: true, measuredAt: .now, centiCelsius: 3875,
      note: "Evening")
    let decoded = try JSONDecoder().decode(WatchDiaryRequest.self, from: JSONEncoder().encode(request))
    #expect(decoded.isWellFormed)
    #expect(decoded.readingID == request.readingID)
    #expect(decoded.centiCelsius == request.centiCelsius)
    #expect(decoded.isNewReading)
  }

  @Test func taggedIdentifiersKeepTheExistingWatchWireShape() throws {
    let familyID = Family.ID(uuidString: "00000000-0000-4000-8000-000000000101")!
    let request = WatchDiaryRequest(action: .startSleep, familyID: familyID, childID: Child.ID(), sessionID: SleepSession.ID())
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(object["familyID"] as? String == familyID.uuidString)
  }

  @Test func aRetriedWakeOnlyTargetsTheSessionTheWatchDisplayed() throws {
    let familyID = Family.ID()
    let childID = Child.ID()
    let originalID = SleepSession.ID()
    let laterID = SleepSession.ID()
    let request = WatchDiaryRequest(action: .endSleep, familyID: familyID, childID: childID, sessionID: originalID)
    let restored = try JSONDecoder().decode(WatchDiaryRequest.self, from: JSONEncoder().encode(request))
    let child = WatchDiaryChild(id: childID, familyID: familyID, familyName: "Family", nickname: "Baby",
      activeSleepID: originalID, activeSleepStartedAt: .now, readings: [])
    let later = WatchDiaryChild(id: childID, familyID: familyID, familyName: "Family", nickname: "Baby",
      activeSleepID: laterID, activeSleepStartedAt: .now, readings: [])
    #expect(restored.sessionID == originalID)
    #expect(restored.targetsActiveSleep(of: child))
    #expect(!restored.targetsActiveSleep(of: later))
  }

  @Test func anUnansweredWatchRequestSurvivesBridgeRecreation() throws {
    let suite = "watch.pending.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let request = WatchDiaryRequest(action: .startSleep, familyID: Family.ID(), childID: Child.ID(),
      sessionID: SleepSession.ID())
    try WatchPendingRequestStore(defaults: defaults).save(request)
    let restored = try #require(WatchPendingRequestStore(defaults: defaults).load())
    #expect(restored.sessionID == request.sessionID)
    #expect(restored.isWellFormed)
    WatchPendingRequestStore(defaults: defaults).clear()
    #expect(WatchPendingRequestStore(defaults: defaults).load() == nil)
  }

  @Test func retryablePhoneRepliesKeepTheWatchIntent() throws {
    let response = WatchDiaryResponse(snapshot: WatchDiarySnapshot(version: 12),
      errorMessage: "Phone app unavailable", retryable: true)
    let restored = try JSONDecoder().decode(WatchDiaryResponse.self, from: JSONEncoder().encode(response))
    #expect(restored.retryable == true)
    #expect(restored.snapshot.version == 12)
  }

  @Test func anOlderPhoneSnapshotCannotReplaceANewerOne() {
    let stale = WatchDiarySnapshot(version: 7)
    let fresh = WatchDiarySnapshot(version: 8)
    #expect(fresh.isNewer(than: stale))
    #expect(!stale.isNewer(than: fresh))
    #expect(!fresh.isNewer(than: fresh))
  }

  @Test func snapshotSelectsTheRequestedChildAndRoundTrips() throws {
    let familyID = Family.ID()
    let family = ModelFixtures.family(id: familyID, name: "Family")
    let first = ModelFixtures.watchChild(
      from: ModelFixtures.child(id: Child.ID(), familyID: familyID, nickname: "First"),
      family: family
    )
    let second = ModelFixtures.watchChild(
      from: ModelFixtures.child(id: Child.ID(), familyID: familyID, nickname: "Second"),
      family: family, activeSleepStartedAt: .now,
      readings: [ModelFixtures.temperature(
        id: TemperatureReading.ID(), familyID: familyID, measuredAt: .now,
        centiCelsius: 3_850, note: "Evening", revision: 2,
        pendingCommandID: PendingCommand.ID()
      )]
    )
    let snapshot = WatchDiarySnapshot(children: [first, second])
    let decoded = try JSONDecoder().decode(WatchDiarySnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded == snapshot)
    #expect(decoded.selectedChild(id: second.id)?.nickname == "Second")
    #expect(decoded.selectedChild(id: Child.ID())?.nickname == "First")
  }
}
