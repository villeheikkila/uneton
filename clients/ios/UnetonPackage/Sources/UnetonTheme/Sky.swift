import Foundation

/// Where the day is, as the amounts the sky reacts to.
///
/// Driven by the local clock, not the sun's real position: the app has no location,
/// and a family's day follows the clock more than the season.
public struct DayPhase: Equatable, Sendable {
  /// Fractional hour of the local day, `0..<24`.
  public let hour: Double
  /// Warm morning glow, `0...1`, peaking at 06:30.
  public let dawn: Double
  /// Rose evening glow, `0...1`, peaking at 19:00.
  public let dusk: Double
  /// `0` at noon, `1` at midnight.
  public let darkness: Double

  public init(hour: Double) {
    let hour = hour.truncatingRemainder(dividingBy: 24) + (hour < 0 ? 24 : 0)
    self.hour = hour
    dawn = Self.glow(hour, peak: 6.5, reach: 1.75)
    dusk = Self.glow(hour, peak: 19, reach: 2)
    darkness = 0.5 + 0.5 * cos(hour / 24 * 2 * .pi)
  }

  public init(date: Date, calendar: Calendar = .current) {
    let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
    let hour = Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
    self.init(hour: hour)
  }

  public static let noon = DayPhase(hour: 12)

  /// A smooth bump that is `1` at `peak` and reaches `0` `reach` hours away.
  private static func glow(_ hour: Double, peak: Double, reach: Double) -> Double {
    let distance = abs(hour - peak)
    let x = (min(distance, 24 - distance) / reach).clamped(to: 0...1)
    return (1 - x * x) * (1 - x * x)
  }
}

/// The background colors of one palette at one moment of the day.
public struct Sky: Equatable, Sendable {
  public var top: RGBColor
  public var middle: RGBColor
  public var bottom: RGBColor
  public var cloud: RGBColor
  public var cloudShade: RGBColor
  /// How visible stars are, `0...1`.
  public var stars: Double

  func mixed(with other: Sky, by amount: Double) -> Sky {
    guard amount > 0 else { return self }
    return Sky(
      top: top.mixed(with: other.top, by: amount),
      middle: middle.mixed(with: other.middle, by: amount),
      bottom: bottom.mixed(with: other.bottom, by: amount),
      cloud: cloud.mixed(with: other.cloud, by: amount),
      cloudShade: cloudShade.mixed(with: other.cloudShade, by: amount),
      stars: stars + (other.stars - stars) * amount
    )
  }

  var backgrounds: [RGBColor] { [top, middle, bottom, cloud, cloudShade] }
}

/// The four skies a palette blends between over a day.
///
/// Blending happens in linear light, so every sky of the day has a luminance between
/// the anchors' luminances. Solving text against the anchors therefore keeps it
/// readable at every hour.
struct SkyAnchors: Equatable, Sendable {
  var noon: Sky
  var midnight: Sky
  var dawn: Sky
  var dusk: Sky

  func sky(at phase: DayPhase) -> Sky {
    noon
      .mixed(with: midnight, by: phase.darkness)
      .mixed(with: dawn, by: phase.dawn)
      .mixed(with: dusk, by: phase.dusk)
  }

  var backgrounds: [RGBColor] { [noon, midnight, dawn, dusk].flatMap(\.backgrounds) }
  var tops: [RGBColor] { [noon, midnight, dawn, dusk].map(\.top) }
}

extension Palette {
  /// The sky for this palette at a moment of the day. `skyTop`, `skyMiddle` and
  /// friends are the noon sky.
  public func sky(at phase: DayPhase) -> Sky {
    skyAnchors.sky(at: phase)
  }
}
