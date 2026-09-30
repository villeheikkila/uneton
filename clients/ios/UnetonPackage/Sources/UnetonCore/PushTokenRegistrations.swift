import Foundation
import Tagged

/// Account-scoped, latest-value registration work. Persist before network I/O.
public struct PushTokenRegistrations: Codable, Equatable, Sendable {
  public private(set) var revision: Int64 = 0
  public private(set) var activityRevisions: [SleepSession.ID: Int64] = [:]
  public var owner: UserID?
  public var apnsToken: String?
  public var pushToStartToken: String?
  public private(set) var pendingSince: [SleepSession.ID: Date] = [:]
  public private(set) var activities: [SleepSession.ID: String] = [:]

  public init() {}

  public mutating func reserveRevision() -> Int64 {
    revision += 1
    return revision
  }

  public mutating func bind(to userID: UserID) {
    if let owner, owner != userID {
      // Device tokens remain valid, but activity work must never cross accounts.
      activities.removeAll()
      pendingSince.removeAll()
      activityRevisions.removeAll()
    }
    owner = userID
  }

  public mutating func record(sessionID: SleepSession.ID, token: String, now: Date) {
    guard activities[sessionID] != token else { return }
    activityRevisions[sessionID] = reserveRevision()
    activities[sessionID] = token
    pendingSince[sessionID] = pendingSince[sessionID] ?? now
  }

  public mutating func acknowledge(sessionID: SleepSession.ID, token: String, revision: Int64) {
    guard activities[sessionID] == token, activityRevisions[sessionID] == revision else { return }
    activities.removeValue(forKey: sessionID)
    pendingSince.removeValue(forKey: sessionID)
    activityRevisions.removeValue(forKey: sessionID)
  }

  public mutating func retainActivities(_ sessionIDs: Set<SleepSession.ID>) {
    activities = activities.filter { sessionIDs.contains($0.key) }
    activityRevisions = activityRevisions.filter { sessionIDs.contains($0.key) }
    pendingSince = pendingSince.filter { sessionIDs.contains($0.key) }
  }
}
