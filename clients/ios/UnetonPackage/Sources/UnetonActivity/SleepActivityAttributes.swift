import Foundation

#if os(iOS)
import ActivityKit

public struct SleepActivityAttributes: ActivityAttributes, Sendable {
  public struct ContentState: Codable, Hashable, Sendable {
    public var endedAt: Date?

    public init(endedAt: Date? = nil) { self.endedAt = endedAt }
  }

  public var familyID: UUID
  public var childID: UUID
  public var sessionID: UUID
  public var childName: String
  public var startedAt: Date

  public init(familyID: UUID, childID: UUID, sessionID: UUID, childName: String, startedAt: Date) {
    self.familyID = familyID
    self.childID = childID
    self.sessionID = sessionID
    self.childName = childName
    self.startedAt = startedAt
  }
}
#endif
