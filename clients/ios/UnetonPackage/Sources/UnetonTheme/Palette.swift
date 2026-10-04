import Foundation

/// The one color a palette grows from. Today every child uses `.sky`; a child color
/// setting only has to store a seed and pass it to `Palette.make`.
public struct PaletteSeed: Equatable, Hashable, Sendable {
  public var hue: Double
  public var chroma: Double

  public init(hue: Double, chroma: Double = 0.11) {
    self.hue = hue.truncatingRemainder(dividingBy: 360) + (hue < 0 ? 360 : 0)
    self.chroma = chroma.clamped(to: 0...0.16)
  }

  /// Derives a seed from any picked color. Chroma is kept soft so a loud pick still
  /// produces a calm palette.
  public init(_ color: RGBColor) {
    let oklch = OKLCH(color)
    self.init(hue: oklch.hue, chroma: oklch.chroma.clamped(to: 0.03...0.16))
  }

  public init?(hex: String) {
    guard let color = RGBColor(hex: hex) else { return nil }
    self.init(color)
  }

  public static let sky = PaletteSeed(hue: 242, chroma: 0.11)
  public static let blossom = PaletteSeed(hue: 352, chroma: 0.11)
  public static let lavender = PaletteSeed(hue: 295, chroma: 0.11)
  public static let meadow = PaletteSeed(hue: 155, chroma: 0.10)
  public static let honey = PaletteSeed(hue: 75, chroma: 0.10)
}

public enum PaletteMode: String, CaseIterable, Sendable {
  /// Light sky for daytime use.
  case day
  /// Dark sky while a night sleep runs or the device prefers dark appearance.
  case night
  /// Very dim, low-blue amber for checking the phone in a dark room.
  case nightLight
}

/// Semantic colors for one child and one mode.
///
/// Every role is derived from the seed with OKLCH math, and every text role is
/// solved against the backgrounds it sits on, so contrast holds for any seed hue
/// (`PaletteTests` sweeps the hue circle). Views use roles, never raw colors.
public struct Palette: Equatable, Sendable {
  public let seed: PaletteSeed
  public let mode: PaletteMode

  /// Background gradient at noon, top to bottom. `sky(at:)` gives other hours.
  public let skyTop: RGBColor
  public let skyMiddle: RGBColor
  public let skyBottom: RGBColor
  /// Decorative clouds and their soft shadow.
  public let cloud: RGBColor
  public let cloudShade: RGBColor
  /// Sun by day, moon by night.
  public let celestial: RGBColor

  /// Primary text, at least 7:1 on the sky and clouds.
  public let ink: RGBColor
  /// Secondary text, at least 4.5:1 on the sky and clouds.
  public let inkSecondary: RGBColor

  /// Prominent actions and night sleep marks.
  public let accent: RGBColor
  /// Text and symbols on `accent`, at least 4.5:1.
  public let onAccent: RGBColor
  /// Nap marks and quieter highlights.
  public let accentSoft: RGBColor
  /// Empty part of tracks and strips.
  public let track: RGBColor
  /// Tint for glass surfaces.
  public let surface: RGBColor

  /// The warm "woke up" action, independent of the seed so it always reads as morning.
  public let wake: RGBColor
  /// Text and symbols on `wake`, at least 4.5:1.
  public let onWake: RGBColor

  /// Noon, midnight, dawn and dusk skies that `sky(at:)` blends between.
  let skyAnchors: SkyAnchors

  public static func make(seed: PaletteSeed = .sky, mode: PaletteMode) -> Palette {
    switch mode {
    case .day: day(seed)
    case .night: night(seed)
    case .nightLight: nightLight(seed)
    }
  }

  private static let warmHue = 85.0
  private static let white = RGBColor(red: 1, green: 1, blue: 1)

  private static func day(_ seed: PaletteSeed) -> Palette {
    let h = seed.hue
    let c = seed.chroma
    let skyTop = OKLCH(lightness: 0.875, chroma: c * 0.45, hue: h).rgb
    let cloud = OKLCH(lightness: 0.995, chroma: 0.006, hue: h).rgb
    let cloudShade = OKLCH(lightness: 0.84, chroma: c * 0.35, hue: h).rgb
    let noon = Sky(
      top: skyTop,
      middle: OKLCH(lightness: 0.92, chroma: c * 0.32, hue: h).rgb,
      bottom: OKLCH(lightness: 0.96, chroma: c * 0.18, hue: h).rgb,
      cloud: cloud, cloudShade: cloudShade, stars: 0
    )
    // Every anchor keeps noon's lightness steps, so only hue and chroma move and the
    // dark text stays readable through the day.
    let anchors = SkyAnchors(
      noon: noon,
      midnight: Sky(
        top: OKLCH(lightness: 0.875, chroma: c * 0.55, hue: h + 15).rgb,
        middle: OKLCH(lightness: 0.92, chroma: c * 0.4, hue: h + 15).rgb,
        bottom: OKLCH(lightness: 0.96, chroma: c * 0.22, hue: h + 20).rgb,
        cloud: cloud,
        cloudShade: OKLCH(lightness: 0.84, chroma: c * 0.4, hue: h + 15).rgb,
        stars: 0
      ),
      dawn: Sky(
        top: skyTop,
        middle: OKLCH(lightness: 0.92, chroma: 0.035, hue: 20).rgb,
        bottom: OKLCH(lightness: 0.96, chroma: 0.045, hue: 70).rgb,
        cloud: OKLCH(lightness: 0.995, chroma: 0.01, hue: 70).rgb,
        cloudShade: OKLCH(lightness: 0.84, chroma: 0.035, hue: 15).rgb,
        stars: 0
      ),
      dusk: Sky(
        top: OKLCH(lightness: 0.875, chroma: max(c * 0.5, 0.04), hue: h + 45).rgb,
        middle: OKLCH(lightness: 0.92, chroma: 0.04, hue: 350).rgb,
        bottom: OKLCH(lightness: 0.96, chroma: 0.05, hue: 50).rgb,
        cloud: OKLCH(lightness: 0.99, chroma: 0.012, hue: 40).rgb,
        cloudShade: OKLCH(lightness: 0.84, chroma: 0.04, hue: 330).rgb,
        stars: 0
      )
    )
    let backgrounds = anchors.backgrounds
    let ink = solve(OKLCH(lightness: 0.34, chroma: c * 0.55, hue: h), against: backgrounds, ratio: 7, darker: true)
    let wake = OKLCH(lightness: 0.93, chroma: 0.07, hue: warmHue).rgb
    return Palette(
      seed: seed, mode: .day,
      skyTop: skyTop,
      skyMiddle: noon.middle,
      skyBottom: noon.bottom,
      cloud: cloud,
      cloudShade: cloudShade,
      celestial: OKLCH(lightness: 0.92, chroma: 0.085, hue: warmHue).rgb,
      ink: ink,
      inkSecondary: solve(OKLCH(lightness: 0.52, chroma: c * 0.5, hue: h), against: backgrounds, ratio: 4.5, darker: true),
      accent: solve(OKLCH(lightness: 0.52, chroma: min(c * 1.3, 0.17), hue: h), against: [white], ratio: 4.5, darker: true),
      onAccent: white,
      accentSoft: OKLCH(lightness: 0.74, chroma: c * 1.05, hue: h).rgb,
      track: OKLCH(lightness: 0.90, chroma: c * 0.30, hue: h).rgb,
      surface: OKLCH(lightness: 0.99, chroma: c * 0.06, hue: h).rgb,
      wake: wake,
      onWake: solve(OKLCH(ink), against: [wake], ratio: 4.5, darker: true),
      skyAnchors: anchors
    )
  }

  private static func night(_ seed: PaletteSeed) -> Palette {
    let h = seed.hue
    let c = seed.chroma
    let skyTop = OKLCH(lightness: 0.27, chroma: c * 0.6, hue: h).rgb
    let skyBottom = OKLCH(lightness: 0.40, chroma: c * 0.55, hue: h).rgb
    let cloud = OKLCH(lightness: 0.43, chroma: c * 0.5, hue: h).rgb
    let noon = Sky(
      top: skyTop,
      middle: OKLCH(lightness: 0.33, chroma: c * 0.62, hue: h).rgb,
      bottom: skyBottom,
      cloud: cloud,
      cloudShade: OKLCH(lightness: 0.39, chroma: c * 0.5, hue: h).rgb,
      stars: 0.55
    )
    // Midnight only gets darker, and dawn and dusk keep noon's lightness, so the
    // light text stays readable through the night.
    let anchors = SkyAnchors(
      noon: noon,
      midnight: Sky(
        top: OKLCH(lightness: 0.22, chroma: c * 0.6, hue: h).rgb,
        middle: OKLCH(lightness: 0.28, chroma: c * 0.6, hue: h).rgb,
        bottom: OKLCH(lightness: 0.35, chroma: c * 0.55, hue: h).rgb,
        cloud: OKLCH(lightness: 0.38, chroma: c * 0.5, hue: h).rgb,
        cloudShade: OKLCH(lightness: 0.34, chroma: c * 0.5, hue: h).rgb,
        stars: 1
      ),
      dawn: Sky(
        top: skyTop,
        middle: OKLCH(lightness: 0.33, chroma: 0.05, hue: 330).rgb,
        bottom: OKLCH(lightness: 0.40, chroma: 0.06, hue: 40).rgb,
        cloud: OKLCH(lightness: 0.43, chroma: 0.04, hue: 20).rgb,
        cloudShade: OKLCH(lightness: 0.39, chroma: 0.04, hue: 340).rgb,
        stars: 0.25
      ),
      dusk: Sky(
        top: OKLCH(lightness: 0.27, chroma: c * 0.7, hue: h + 30).rgb,
        middle: OKLCH(lightness: 0.33, chroma: 0.06, hue: 320).rgb,
        bottom: OKLCH(lightness: 0.40, chroma: 0.07, hue: 25).rgb,
        cloud: OKLCH(lightness: 0.43, chroma: 0.045, hue: 350).rgb,
        cloudShade: OKLCH(lightness: 0.39, chroma: 0.045, hue: 320).rgb,
        stars: 0.3
      )
    )
    let backgrounds = anchors.backgrounds
    let wake = OKLCH(lightness: 0.90, chroma: 0.08, hue: warmHue).rgb
    return Palette(
      seed: seed, mode: .night,
      skyTop: skyTop,
      skyMiddle: noon.middle,
      skyBottom: skyBottom,
      cloud: cloud,
      cloudShade: noon.cloudShade,
      celestial: OKLCH(lightness: 0.95, chroma: 0.05, hue: 90).rgb,
      ink: solve(OKLCH(lightness: 0.97, chroma: 0.012, hue: h), against: backgrounds, ratio: 7, darker: false),
      inkSecondary: solve(OKLCH(lightness: 0.86, chroma: c * 0.3, hue: h), against: backgrounds, ratio: 4.5, darker: false),
      accent: solve(OKLCH(lightness: 0.80, chroma: c * 0.8, hue: h), against: anchors.tops, ratio: 4.5, darker: false),
      onAccent: skyTop,
      accentSoft: OKLCH(lightness: 0.66, chroma: c * 0.7, hue: h).rgb,
      track: OKLCH(lightness: 0.40, chroma: c * 0.35, hue: h).rgb,
      surface: OKLCH(lightness: 0.38, chroma: c * 0.4, hue: h).rgb,
      wake: wake,
      onWake: solve(OKLCH(skyTop), against: [wake], ratio: 4.5, darker: true),
      skyAnchors: anchors
    )
  }

  /// Night light ignores the seed hue on purpose: its job is low blue light, so it
  /// stays amber for every child.
  private static func nightLight(_ seed: PaletteSeed) -> Palette {
    let h = 58.0
    let skyTop = OKLCH(lightness: 0.15, chroma: 0.012, hue: h).rgb
    let skyBottom = OKLCH(lightness: 0.16, chroma: 0.014, hue: h).rgb
    let wake = OKLCH(lightness: 0.28, chroma: 0.05, hue: h).rgb
    let ink = solve(OKLCH(lightness: 0.72, chroma: 0.10, hue: h), against: [skyBottom, wake], ratio: 7, darker: false)
    // No time of day and no stars: night light exists to stay dim and still.
    let sky = Sky(top: skyTop, middle: skyTop, bottom: skyBottom, cloud: skyBottom, cloudShade: skyTop, stars: 0)
    return Palette(
      seed: seed, mode: .nightLight,
      skyTop: skyTop,
      skyMiddle: skyTop,
      skyBottom: skyBottom,
      cloud: skyBottom,
      cloudShade: skyTop,
      celestial: OKLCH(lightness: 0.55, chroma: 0.08, hue: 60).rgb,
      ink: ink,
      inkSecondary: solve(OKLCH(lightness: 0.58, chroma: 0.08, hue: h), against: [skyBottom], ratio: 4.5, darker: false),
      accent: solve(OKLCH(lightness: 0.62, chroma: 0.11, hue: h), against: [skyTop], ratio: 4.5, darker: false),
      onAccent: skyTop,
      accentSoft: OKLCH(lightness: 0.45, chroma: 0.08, hue: h).rgb,
      track: OKLCH(lightness: 0.22, chroma: 0.02, hue: h).rgb,
      surface: OKLCH(lightness: 0.20, chroma: 0.02, hue: h).rgb,
      wake: wake,
      onWake: ink,
      skyAnchors: SkyAnchors(noon: sky, midnight: sky, dawn: sky, dusk: sky)
    )
  }

  /// Moves lightness until the color reaches `ratio` against every background.
  /// Chroma is reduced automatically by gamut mapping as lightness nears 0 or 1, so
  /// the walk always ends at a displayable color.
  static func solve(_ start: OKLCH, against backgrounds: [RGBColor], ratio: Double, darker: Bool) -> RGBColor {
    var color = start
    let step = darker ? -0.005 : 0.005
    while true {
      let rgb = color.rgb
      if backgrounds.allSatisfy({ rgb.contrast(with: $0) >= ratio }) { return rgb }
      let next = color.lightness + step
      guard (0...1).contains(next) else { return rgb }
      color.lightness = next
    }
  }
}

/// Decides which palette mode a screen shows. Whether a sleep is a night sleep is a
/// domain question (`SleepKind` in UnetonCore); this only maps the answer to colors.
public enum SleepAppearance {
  public static func mode(nightSleepActive: Bool, prefersDark: Bool, nightLightEnabled: Bool) -> PaletteMode {
    if nightSleepActive && nightLightEnabled { return .nightLight }
    if nightSleepActive || prefersDark { return .night }
    return .day
  }
}
