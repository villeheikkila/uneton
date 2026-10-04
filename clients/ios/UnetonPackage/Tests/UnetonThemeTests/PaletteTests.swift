import Foundation
import Testing
@testable import UnetonTheme

@Suite("Palette")
struct PaletteTests {
  static let hues = stride(from: 0.0, to: 360.0, by: 10.0).map { $0 }
  static let chromas = [0.0, 0.04, 0.11, 0.16]

  static var seeds: [PaletteSeed] {
    hues.flatMap { hue in chromas.map { PaletteSeed(hue: hue, chroma: $0) } }
  }

  @Test("OKLCH round-trips sRGB", arguments: ["#000000", "#FFFFFF", "#1F66A8", "#F7B8CB", "#7DBF9E"])
  func roundTrip(hex: String) throws {
    let color = try #require(RGBColor(hex: hex))
    #expect(OKLCH(color).rgb.hex == hex)
  }

  @Test func whiteHasFullLightnessAndNoChroma() {
    let white = OKLCH(RGBColor(red: 1, green: 1, blue: 1))
    #expect(abs(white.lightness - 1) < 0.001)
    #expect(white.chroma < 0.001)
  }

  @Test func contrastMatchesWCAG() {
    let black = RGBColor(red: 0, green: 0, blue: 0)
    let white = RGBColor(red: 1, green: 1, blue: 1)
    #expect(abs(black.contrast(with: white) - 21) < 0.01)
    #expect(abs(white.contrast(with: white) - 1) < 0.001)
  }

  @Test func outOfGamutColorsMapIntoSRGB() {
    let loud = OKLCH(lightness: 0.7, chroma: 0.4, hue: 150).rgb
    #expect(loud.isInGamut)
  }

  @Test func seedFromPickedColorKeepsHueAndSoftensChroma() throws {
    let pink = try #require(PaletteSeed(hex: "#FF2D8A"))
    #expect(pink.chroma <= 0.16)
    let distanceFromPink = min(abs(pink.hue - 355), 360 - abs(pink.hue - 355))
    #expect(distanceFromPink < 20)
  }

  @Test("Text keeps contrast for every seed", arguments: PaletteMode.allCases)
  func textContrast(mode: PaletteMode) {
    for seed in Self.seeds {
      let palette = Palette.make(seed: seed, mode: mode)
      let label = "\(mode) hue \(seed.hue) chroma \(seed.chroma)"
      for background in [palette.skyTop, palette.skyMiddle, palette.skyBottom, palette.cloud] {
        #expect(palette.ink.contrast(with: background) >= 7, "\(label): ink")
        #expect(palette.inkSecondary.contrast(with: background) >= 4.5, "\(label): secondary ink")
      }
      #expect(palette.onAccent.contrast(with: palette.accent) >= 4.5, "\(label): on accent")
      #expect(palette.onWake.contrast(with: palette.wake) >= 4.5, "\(label): on wake")
    }
  }

  @Test("Text keeps contrast at every hour", arguments: PaletteMode.allCases)
  func textContrastThroughTheDay(mode: PaletteMode) {
    for seed in Self.seeds {
      let palette = Palette.make(seed: seed, mode: mode)
      for minute in stride(from: 0, to: 24 * 60, by: 15) {
        let sky = palette.sky(at: DayPhase(hour: Double(minute) / 60))
        let label = "\(mode) hue \(seed.hue) chroma \(seed.chroma) minute \(minute)"
        for background in [sky.top, sky.middle, sky.bottom, sky.cloud] {
          #expect(palette.ink.contrast(with: background) >= 7, "\(label): ink")
          #expect(palette.inkSecondary.contrast(with: background) >= 4.5, "\(label): secondary ink")
        }
      }
    }
  }

  @Test func noonSkyIsThePaletteSky() {
    let palette = Palette.make(seed: .sky, mode: .day)
    let sky = palette.sky(at: .noon)
    #expect(sky.top.contrast(with: palette.skyTop) < 1.01)
    #expect(sky.bottom.contrast(with: palette.skyBottom) < 1.01)
  }

  @Test func dayPhaseGlowsAtDawnAndDuskAndDarkensAtMidnight() {
    #expect(DayPhase(hour: 6.5).dawn == 1)
    #expect(DayPhase(hour: 19).dusk == 1)
    #expect(DayPhase(hour: 12).dawn == 0 && DayPhase(hour: 12).dusk == 0)
    #expect(abs(DayPhase(hour: 0).darkness - 1) < 0.001)
    #expect(abs(DayPhase(hour: 12).darkness) < 0.001)
    #expect(DayPhase(hour: 25) == DayPhase(hour: 1))
  }

  @Test func starsOnlyShowInTheNightSky() {
    let midnight = DayPhase(hour: 0)
    #expect(Palette.make(seed: .sky, mode: .day).sky(at: midnight).stars == 0)
    #expect(Palette.make(seed: .sky, mode: .night).sky(at: midnight).stars > 0.9)
    #expect(Palette.make(seed: .sky, mode: .nightLight).sky(at: midnight).stars == 0)
  }

  @Test("Night light stays amber whatever the seed")
  func nightLightIgnoresSeed() {
    let sky = Palette.make(seed: .sky, mode: .nightLight)
    let blossom = Palette.make(seed: .blossom, mode: .nightLight)
    #expect(sky.ink == blossom.ink)
    #expect(sky.skyTop == blossom.skyTop)
  }

  @Test("Different seeds give different day accents")
  func seedsChangeAccent() {
    #expect(Palette.make(seed: .sky, mode: .day).accent != Palette.make(seed: .blossom, mode: .day).accent)
  }
}

@Suite("Sleep appearance")
struct SleepAppearanceTests {
  @Test func modeFollowsNightSleepDarkModeAndNightLight() {
    #expect(SleepAppearance.mode(nightSleepActive: false, prefersDark: false, nightLightEnabled: true) == .day)
    #expect(SleepAppearance.mode(nightSleepActive: false, prefersDark: true, nightLightEnabled: true) == .night)
    #expect(SleepAppearance.mode(nightSleepActive: true, prefersDark: false, nightLightEnabled: false) == .night)
    #expect(SleepAppearance.mode(nightSleepActive: true, prefersDark: false, nightLightEnabled: true) == .nightLight)
  }
}
