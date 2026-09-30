import CustomDump
import Foundation
import Testing
import Tagged
@testable import UnetonCore

struct PushTokenRegistrationsTests {
  let session = SleepSession.ID(uuidString: "00000000-0000-4000-8000-000000000001")!
  let owner = UserID(uuidString: "00000000-0000-4000-8000-000000000002")!
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func failedUploadSurvivesRestartAndAcknowledgesOnlyLatestToken() throws {
    var work = PushTokenRegistrations()
    work.bind(to: owner)
    work.apnsToken = "device"
    work.pushToStartToken = "start"
    work.record(sessionID: session, token: "old", now: now)
    work = try JSONDecoder().decode(PushTokenRegistrations.self, from: JSONEncoder().encode(work))
    work.record(sessionID: session, token: "rotated", now: now.addingTimeInterval(60))
    work.acknowledge(sessionID: session, token: "old", revision: 1)
    expectNoDifference(work.activities, [session: "rotated"])
    expectNoDifference(work.pendingSince, [session: now])
    work.acknowledge(sessionID: session, token: "rotated", revision: 2)
    #expect(work.activities.isEmpty)
    #expect(work.pendingSince.isEmpty)
    expectNoDifference(work.apnsToken, "device")
    expectNoDifference(work.pushToStartToken, "start")
  }

  @Test func aRepeatedTokenCannotBeAcknowledgedByAnOlderUpload() throws {
    var work = PushTokenRegistrations()
    work.record(sessionID: session, token: "first", now: now)
    work.record(sessionID: session, token: "second", now: now)
    work.record(sessionID: session, token: "first", now: now)
    work.acknowledge(sessionID: session, token: "first", revision: 1)
    expectNoDifference(work.activities, [session: "first"])
    let restored = try JSONDecoder().decode(PushTokenRegistrations.self, from: JSONEncoder().encode(work))
    expectNoDifference(restored.revision, 3)
    expectNoDifference(restored.activityRevisions, [session: 3])
  }

  @Test func accountSwitchNeverTransfersActivityRegistrations() {
    var work = PushTokenRegistrations()
    work.bind(to: owner)
    work.apnsToken = "device"
    work.record(sessionID: session, token: "activity", now: now)
    work.bind(to: UserID(uuidString: "00000000-0000-4000-8000-000000000003")!)
    #expect(work.activities.isEmpty)
    #expect(work.pendingSince.isEmpty)
    expectNoDifference(work.apnsToken, "device")
  }

  @Test func removedMembershipPrunesWorkButKeepsAccessibleEndedSessions() {
    var work = PushTokenRegistrations()
    work.record(sessionID: session, token: "late-end", now: now)
    let removed = SleepSession.ID(uuidString: "00000000-0000-4000-8000-000000000004")!
    work.record(sessionID: removed, token: "removed", now: now)
    work.retainActivities([session])
    expectNoDifference(work.activities, [session: "late-end"])
  }

  @Test(.timeLimit(.minutes(1))) func observersRunConcurrentlyAndDeduplicateUntilCancelled() async {
    let observers = ConcurrentTokenObservers()
    let (started, didStart) = AsyncStream<String>.makeStream()
    let (gate, holdOpen) = AsyncStream<Void>.makeStream()
    await observers.start(id: "first") {
      didStart.yield("first")
      for await _ in gate {}
    }
    await observers.start(id: "first") { didStart.yield("duplicate") }
    await observers.start(id: "second") {
      didStart.yield("second")
      for await _ in gate {}
    }
    var iterator = started.makeAsyncIterator()
    let first = await iterator.next()
    let second = await iterator.next()
    expectNoDifference(Set([first, second].compactMap { $0 }), ["first", "second"])
    await observers.cancelAll()
    holdOpen.finish()
    didStart.finish()
    #expect(await iterator.next() == nil)
  }
}
