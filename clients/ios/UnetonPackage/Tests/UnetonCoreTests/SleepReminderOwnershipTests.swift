import CustomDump
import Foundation
import Testing
@testable import UnetonCore

struct SleepReminderOwnershipTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func forecast(target: Date, provisional: Bool = false, active: Bool = false) -> SleepForecast {
    SleepForecast(activeSleepID: active ? SleepSession.ID(uuidString: "00000000-0000-4000-8000-000000000001")! : nil,
      nextSleepEstimate: SleepPrediction(targetAt: target, rangeStartAt: target,
        rangeEndAt: target, confidence: "low", explanation: "Estimate", algorithmVersion: 3),
      nextSleepIsProvisional: provisional)
  }

  @Test func ownershipPersistsAcrossLostResponsesAndRestart() throws {
    var ownership = SleepReminderOwnership()
    ownership.reserve(until: now.addingTimeInterval(SleepReminderOwnership.duration))
    let restored = try JSONDecoder().decode(SleepReminderOwnership.self,
      from: JSONEncoder().encode(ownership))
    expectNoDifference(restored, ownership)
    #expect(restored.localFireDate(forecast: forecast(target: now.addingTimeInterval(3600)),
      notificationsEnabled: true, leadMinutes: 15, now: now) == nil)
  }

  @Test func aLateReservationCannotShortenRemoteOwnership() {
    var ownership = SleepReminderOwnership(remoteUntil: now.addingTimeInterval(3600))
    ownership.reserve(until: now.addingTimeInterval(1800))
    expectNoDifference(ownership.remoteUntil, now.addingTimeInterval(3600))
  }

  @Test func localFallbackBeginsAtTheOwnershipBoundary() {
    let boundary = now.addingTimeInterval(3600)
    let ownership = SleepReminderOwnership(remoteUntil: boundary)
    let before = forecast(target: boundary.addingTimeInterval(15 * 60 - 1))
    let after = forecast(target: boundary.addingTimeInterval(15 * 60))
    #expect(ownership.localFireDate(forecast: before, notificationsEnabled: true,
      leadMinutes: 15, now: now) == nil)
    expectNoDifference(ownership.localFireDate(forecast: after, notificationsEnabled: true,
      leadMinutes: 15, now: now), boundary)
  }

  @Test func unavailableRemoteDeliveryRetainsALocalReminder() {
    let ownership = SleepReminderOwnership()
    expectNoDifference(ownership.localFireDate(forecast: forecast(target: now.addingTimeInterval(3600)),
      notificationsEnabled: true, leadMinutes: 15, now: now), now.addingTimeInterval(2700))
  }

  @Test func sleepingProvisionalDisabledAndPastRemindersAreSuppressed() {
    let ownership = SleepReminderOwnership()
    for value in [forecast(target: now.addingTimeInterval(3600), provisional: true),
      forecast(target: now.addingTimeInterval(3600), active: true), forecast(target: now)] {
      #expect(ownership.localFireDate(forecast: value, notificationsEnabled: true,
        leadMinutes: 15, now: now) == nil)
    }
    #expect(ownership.localFireDate(forecast: forecast(target: now.addingTimeInterval(3600)),
      notificationsEnabled: false, leadMinutes: 15, now: now) == nil)
  }
}
