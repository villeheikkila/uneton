import Foundation
import Tagged

public enum TemperatureValue {
  public static func centiCelsius(from text: String) -> Int? {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ",", with: ".")
    guard let value = Double(normalized), value.isFinite,
          (20...50).contains(value) else { return nil }
    return Int((value * 100).rounded())
  }

  public static func isValid(_ centiCelsius: Int) -> Bool {
    2000...5000 ~= centiCelsius
  }
}

public enum WatchDiaryAction: String, Codable, Sendable {
  case status
  case startSleep
  case endSleep
  case upsertTemperature
  case deleteTemperature
}

public struct WatchDiaryRequest: Codable, Sendable {
  public var action: WatchDiaryAction
  public var familyID: Family.ID?
  public var childID: Child.ID?
  public var sessionID: SleepSession.ID?
  public var readingID: TemperatureReading.ID?
  public var expectedRevision: Int?
  public var isNewReading: Bool
  public var measuredAt: Date?
  public var centiCelsius: Int?
  public var note: String

  public init(action: WatchDiaryAction, familyID: Family.ID? = nil, childID: Child.ID? = nil,
              sessionID: SleepSession.ID? = nil,
              readingID: TemperatureReading.ID? = nil, expectedRevision: Int? = nil, isNewReading: Bool = false,
              measuredAt: Date? = nil, centiCelsius: Int? = nil, note: String = "") {
    self.action = action
    self.familyID = familyID
    self.childID = childID
    self.sessionID = sessionID
    self.readingID = readingID
    self.expectedRevision = expectedRevision
    self.isNewReading = isNewReading
    self.measuredAt = measuredAt
    self.centiCelsius = centiCelsius
    self.note = note
  }

  public var isWellFormed: Bool {
    if action == .status { return true }
    guard familyID != nil, childID != nil else { return false }
    switch action {
    case .status:
      return true
    case .startSleep, .endSleep:
      return sessionID != nil
    case .upsertTemperature:
      return readingID != nil && measuredAt != nil && centiCelsius.map(TemperatureValue.isValid) == true
        && (isNewReading || expectedRevision != nil)
    case .deleteTemperature:
      return readingID != nil && expectedRevision != nil
    }
  }

  public func targetsActiveSleep(of child: WatchDiaryChild) -> Bool {
    action == .endSleep && familyID == child.familyID && childID == child.id
      && sessionID != nil && sessionID == child.activeSleepID
  }
}

public struct WatchDiaryReading: Codable, Equatable, Identifiable, Sendable {
  public typealias ID = TemperatureReading.ID
  public var id: ID
  public var measuredAt: Date
  public var centiCelsius: Int
  public var note: String
  public var revision: Int
  public var isPending: Bool

  public init(id: ID, measuredAt: Date, centiCelsius: Int, note: String, revision: Int, isPending: Bool) {
    self.id = id
    self.measuredAt = measuredAt
    self.centiCelsius = centiCelsius
    self.note = note
    self.revision = revision
    self.isPending = isPending
  }
}

public struct WatchDiaryChild: Codable, Equatable, Identifiable, Sendable {
  public typealias ID = Child.ID
  public var id: ID
  public var familyID: Family.ID
  public var familyName: String
  public var nickname: String
  public var activeSleepID: SleepSession.ID?
  public var activeSleepStartedAt: Date?
  public var readings: [WatchDiaryReading]

  public init(id: ID, familyID: Family.ID, familyName: String, nickname: String,
              activeSleepID: SleepSession.ID? = nil, activeSleepStartedAt: Date?, readings: [WatchDiaryReading]) {
    self.id = id
    self.familyID = familyID
    self.familyName = familyName
    self.nickname = nickname
    self.activeSleepID = activeSleepID
    self.activeSleepStartedAt = activeSleepStartedAt
    self.readings = readings
  }
}

public struct WatchDiarySnapshot: Codable, Equatable, Sendable {
  public var version: Int
  public var children: [WatchDiaryChild]

  public init(version: Int = 0, children: [WatchDiaryChild] = []) {
    self.version = version
    self.children = children
  }

  public func isNewer(than other: Self) -> Bool { version > other.version }

  public func selectedChild(id: Child.ID?) -> WatchDiaryChild? {
    children.first { $0.id == id } ?? children.first
  }
}

public struct WatchDiaryResponse: Codable, Sendable {
  public var snapshot: WatchDiarySnapshot
  public var errorMessage: String?
  public var notice: String?
  public var retryable: Bool?

  public init(snapshot: WatchDiarySnapshot, errorMessage: String? = nil, notice: String? = nil,
              retryable: Bool? = nil) {
    self.snapshot = snapshot
    self.errorMessage = errorMessage
    self.notice = notice
    self.retryable = retryable
  }
}

/// Persists the one Watch intent that has not received a definitive phone reply.
public struct WatchPendingRequestStore {
  private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults = .standard, key: String = "watch.pendingDiaryRequest") {
    self.defaults = defaults
    self.key = key
  }

  public func load() -> WatchDiaryRequest? {
    defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(WatchDiaryRequest.self, from: $0) }
  }

  public func save(_ request: WatchDiaryRequest) throws {
    defaults.set(try JSONEncoder().encode(request), forKey: key)
  }

  public func clear() {
    defaults.removeObject(forKey: key)
  }
}
