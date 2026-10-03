import Foundation

/// An sRGB color with gamma-encoded channels in `0...1`.
public struct RGBColor: Equatable, Hashable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double

  public init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  /// Parses `#RRGGBB` or `RRGGBB`. Returns `nil` for anything else.
  public init?(hex: String) {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
    self.init(
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255
    )
  }

  public var hex: String {
    let channels = [red, green, blue].map { Int(($0.clamped(to: 0...1) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
  }

  var isInGamut: Bool {
    let range = -0.000_1...1.000_1
    return range.contains(red) && range.contains(green) && range.contains(blue)
  }

  var clamped: RGBColor {
    RGBColor(red: red.clamped(to: 0...1), green: green.clamped(to: 0...1), blue: blue.clamped(to: 0...1))
  }

  /// WCAG 2 relative luminance.
  public var relativeLuminance: Double {
    let linear = clamped.linear
    return 0.2126 * linear.red + 0.7152 * linear.green + 0.0722 * linear.blue
  }

  /// WCAG 2 contrast ratio between two colors, `1...21`.
  public func contrast(with other: RGBColor) -> Double {
    let lighter = max(relativeLuminance, other.relativeLuminance)
    let darker = min(relativeLuminance, other.relativeLuminance)
    return (lighter + 0.05) / (darker + 0.05)
  }

  fileprivate var linear: (red: Double, green: Double, blue: Double) {
    (Self.decode(red), Self.decode(green), Self.decode(blue))
  }

  fileprivate static func decode(_ channel: Double) -> Double {
    channel <= 0.040_45 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
  }

  fileprivate static func encode(_ channel: Double) -> Double {
    channel <= 0.003_130_8 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055
  }
}

/// A color in OKLCH: perceptual lightness `0...1`, chroma, and hue in degrees.
///
/// Palette math happens here because equal steps in OKLCH lightness look equal to
/// people, and changing hue keeps lightness and contrast stable. That is what lets
/// one seed hue produce a whole palette that stays readable for any child color.
public struct OKLCH: Equatable, Hashable, Sendable {
  public var lightness: Double
  public var chroma: Double
  public var hue: Double

  public init(lightness: Double, chroma: Double, hue: Double) {
    self.lightness = lightness
    self.chroma = chroma
    self.hue = hue
  }

  public init(_ rgb: RGBColor) {
    let linear = rgb.clamped.linear
    let l = cbrt(0.412_221_470_8 * linear.red + 0.536_332_536_3 * linear.green + 0.051_445_992_9 * linear.blue)
    let m = cbrt(0.211_903_498_2 * linear.red + 0.680_699_545_1 * linear.green + 0.107_396_956_6 * linear.blue)
    let s = cbrt(0.088_302_461_9 * linear.red + 0.281_718_837_6 * linear.green + 0.629_978_700_5 * linear.blue)
    let okL = 0.210_454_255_3 * l + 0.793_617_785_0 * m - 0.004_072_046_8 * s
    let okA = 1.977_998_495_1 * l - 2.428_592_205_0 * m + 0.450_593_709_9 * s
    let okB = 0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766_0 * s
    let hue = atan2(okB, okA) * 180 / .pi
    self.init(lightness: okL, chroma: (okA * okA + okB * okB).squareRoot(), hue: hue < 0 ? hue + 360 : hue)
  }

  /// The raw conversion, which may fall outside sRGB.
  var unclampedRGB: RGBColor {
    let radians = hue * .pi / 180
    let okA = chroma * cos(radians)
    let okB = chroma * sin(radians)
    let l = pow(lightness + 0.396_337_777_4 * okA + 0.215_803_757_3 * okB, 3)
    let m = pow(lightness - 0.105_561_345_8 * okA - 0.063_854_172_8 * okB, 3)
    let s = pow(lightness - 0.089_484_177_5 * okA - 1.291_485_548_0 * okB, 3)
    return RGBColor(
      red: RGBColor.encode(4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s),
      green: RGBColor.encode(-1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s),
      blue: RGBColor.encode(-0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701_0 * s)
    )
  }

  /// The closest displayable sRGB color, keeping lightness and hue and giving up chroma.
  public var rgb: RGBColor {
    let lightness = lightness.clamped(to: 0...1)
    var candidate = OKLCH(lightness: lightness, chroma: max(0, chroma), hue: hue)
    if candidate.unclampedRGB.isInGamut { return candidate.unclampedRGB.clamped }
    var low = 0.0
    var high = candidate.chroma
    for _ in 0..<24 {
      let middle = (low + high) / 2
      candidate.chroma = middle
      if candidate.unclampedRGB.isInGamut { low = middle } else { high = middle }
    }
    candidate.chroma = low
    return candidate.unclampedRGB.clamped
  }
}

extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
