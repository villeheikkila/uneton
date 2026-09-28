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
    let readingID = TemperatureReading.ID()
    #expect(WatchDiaryRequest(action: .status).isWellFormed)
    #expect(!WatchDiaryRequest(action: .startSleep).isWellFormed)
    #expect(WatchDiaryRequest(action: .startSleep, familyID: familyID, childID: childID).isWellFormed)
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
    let request = WatchDiaryRequest(action: .startSleep, familyID: familyID, childID: Child.ID())
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(object["familyID"] as? String == familyID.uuidString)
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
