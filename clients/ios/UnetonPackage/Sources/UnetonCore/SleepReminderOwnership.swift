import Foundation

/// The phone records ownership before requesting it, including ambiguous RPCs.
/// Only reminders outside that interval may be scheduled locally.
public struct SleepReminderOwnership: Codable, Equatable, Sendable {
  public static let duration: TimeInterval = 24 * 60 * 60
  public var remoteUntil: Date?

  public init(remoteUntil: Date? = nil) { self.remoteUntil = remoteUntil }

  public mutating func reserve(until: Date) {
    remoteUntil = max(remoteUntil ?? .distantPast, until)
  }

  public func localFireDate(forecast: SleepForecast?, notificationsEnabled: Bool,
    leadMinutes: Int, now: Date) -> Date? {
    guard notificationsEnabled, let forecast, !forecast.nextSleepIsProvisional,
      forecast.activeSleepID == nil, let prediction = forecast.nextSleepEstimate
    else { return nil }
    let fireDate = prediction.targetAt.addingTimeInterval(-Double(leadMinutes) * 60)
    guard fireDate > now, remoteUntil.map({ fireDate >= $0 }) ?? true else { return nil }
    return fireDate
  }
}
