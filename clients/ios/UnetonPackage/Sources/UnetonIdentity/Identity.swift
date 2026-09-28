import Foundation
import Tagged

public enum FamilyTag {}
public enum ChildTag {}
public enum SleepSessionTag {}

public typealias FamilyID = Tagged<FamilyTag, UUID>
public typealias ChildID = Tagged<ChildTag, UUID>
public typealias SleepSessionID = Tagged<SleepSessionTag, UUID>

public extension Tagged where RawValue == UUID {
  init() { self.init(rawValue: UUID()) }
  init?(uuidString: String) {
    guard let value = UUID(uuidString: uuidString) else { return nil }
    self.init(rawValue: value)
  }
  var uuidString: String { rawValue.uuidString }
}
