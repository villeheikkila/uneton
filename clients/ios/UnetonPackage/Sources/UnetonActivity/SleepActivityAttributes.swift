import Foundation
import UnetonIdentity

#if os(iOS)
import ActivityKit

public struct SleepActivityAttributes: ActivityAttributes, Sendable {
  public struct ContentState: Codable, Hashable, Sendable {
    public var endedAt: Date?

    public init(endedAt: Date? = nil) { self.endedAt = endedAt }
  }

  public var familyID: FamilyID
  public var childID: ChildID
  public var sessionID: SleepSessionID
  public var childName: String
  public var startedAt: Date

  public init(familyID: FamilyID, childID: ChildID, sessionID: SleepSessionID, childName: String, startedAt: Date) {
    self.familyID = familyID
    self.childID = childID
    self.sessionID = sessionID
    self.childName = childName
    self.startedAt = startedAt
  }
}
#endif
