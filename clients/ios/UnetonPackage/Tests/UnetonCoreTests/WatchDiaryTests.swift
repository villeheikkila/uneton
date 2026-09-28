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
    let familyID = UUID()
    let childID = UUID()
    let readingID = UUID()
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
    let request = WatchDiaryRequest(action: .upsertTemperature, familyID: UUID(), childID: UUID(),
      readingID: UUID(), isNewReading: true, measuredAt: .now, centiCelsius: 3875,
      note: "Evening")
    let decoded = try JSONDecoder().decode(WatchDiaryRequest.self, from: JSONEncoder().encode(request))
    #expect(decoded.isWellFormed)
    #expect(decoded.readingID == request.readingID)
    #expect(decoded.centiCelsius == request.centiCelsius)
    #expect(decoded.isNewReading)
  }

  @Test func snapshotSelectsTheRequestedChildAndRoundTrips() throws {
    let familyID = UUID()
    let first = WatchDiaryChild(id: UUID(), familyID: familyID, familyName: "Family",
      nickname: "First", activeSleepStartedAt: nil, readings: [])
    let second = WatchDiaryChild(id: UUID(), familyID: familyID, familyName: "Family",
      nickname: "Second", activeSleepStartedAt: .now,
      readings: [WatchDiaryReading(id: UUID(), measuredAt: .now, centiCelsius: 3850,
        note: "Evening", revision: 2, isPending: true)])
    let snapshot = WatchDiarySnapshot(children: [first, second])
    let decoded = try JSONDecoder().decode(WatchDiarySnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded == snapshot)
    #expect(decoded.selectedChild(id: second.id)?.nickname == "Second")
    #expect(decoded.selectedChild(id: UUID())?.nickname == "First")
  }
}
