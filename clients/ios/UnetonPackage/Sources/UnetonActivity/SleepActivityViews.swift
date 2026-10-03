#if os(iOS)
import SwiftUI
import UnetonTheme

/// Live Activity colors, taken from the shared palette so the lock screen and
/// Dynamic Island match the app. The card is light; the Dynamic Island is dark.
public enum SleepActivityPalette {
  static let day = Palette.make(seed: .sky, mode: .day)
  static let night = Palette.make(seed: .sky, mode: .night)

  public static let ink = day.ink.color
  public static let accent = day.accent.color
  public static let onAccent = day.onAccent.color
  public static let wake = day.wake.color
  public static let onWake = day.onWake.color
  public static let cardBackground = day.skyBottom.color
  public static let mutedInk = day.inkSecondary.color
  public static let mutedOnDark = night.inkSecondary.color
  public static let islandAccent = night.accent.color
}

public struct SleepActivityIdentityView: View {
  public let childName: String
  public let diameter: CGFloat

  public init(childName: String, diameter: CGFloat = 52) {
    self.childName = childName
    self.diameter = diameter
  }

  public var body: some View {
    Text(String(childName.prefix(1)).uppercased())
      .font(.system(size: diameter * 0.46, weight: .medium, design: .rounded))
      .foregroundStyle(SleepActivityPalette.onAccent)
      .frame(width: diameter, height: diameter)
      .background(SleepActivityPalette.accent, in: .circle)
      .accessibilityLabel(Text(childName))
  }
}

public struct SleepActivityWakeLink: View {
  public let endURL: URL
  public let diameter: CGFloat

  public init(endURL: URL, diameter: CGFloat = 52) {
    self.endURL = endURL
    self.diameter = diameter
  }

  public var body: some View {
    Link(destination: endURL) {
      Image(systemName: "stop.fill")
        .font(.system(size: diameter * 0.33, weight: .bold))
        .foregroundStyle(SleepActivityPalette.onWake)
        .frame(width: diameter, height: diameter)
        .background(SleepActivityPalette.wake, in: .circle)
    }
    .accessibilityLabel(Text("locWakeUp", bundle: .module, comment: "Accessible label for the Live Activity stop icon that opens the wake action"))
  }
}

public struct SleepActivitySinceView: View {
  public let startedAt: Date
  public let onDarkBackground: Bool

  public init(startedAt: Date, onDarkBackground: Bool = false) {
    self.startedAt = startedAt
    self.onDarkBackground = onDarkBackground
  }

  public var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "moon.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(SleepActivityPalette.onAccent)
        .frame(width: 24, height: 24)
        .background(SleepActivityPalette.accent, in: .circle)
      Text(.locSleepingSince(startedAt.formatted(date: .omitted, time: .shortened)))
        .font(.caption)
        .foregroundStyle(onDarkBackground ? SleepActivityPalette.mutedOnDark : SleepActivityPalette.mutedInk)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
  }
}

/// ActivityKit supplies the rounded card and its background tint.
public struct SleepActivityLockScreenView: View {
  public let childName: String
  public let startedAt: Date
  public let elapsed: Text
  public let endURL: URL

  public init(childName: String, startedAt: Date, elapsed: Text, endURL: URL) {
    self.childName = childName
    self.startedAt = startedAt
    self.elapsed = elapsed
    self.endURL = endURL
  }

  public var body: some View {
    HStack(spacing: 10) {
      SleepActivityIdentityView(childName: childName)
      Spacer(minLength: 0)
      VStack(spacing: 7) {
        elapsed
          .font(.system(size: 38, weight: .medium, design: .rounded).monospacedDigit())
          .foregroundStyle(SleepActivityPalette.ink)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        SleepActivitySinceView(startedAt: startedAt)
      }
      .frame(maxWidth: .infinity)
      Spacer(minLength: 0)
      SleepActivityWakeLink(endURL: endURL)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}

public struct SleepActivityExpandedCenterView: View {
  public let elapsed: Text

  public init(elapsed: Text) { self.elapsed = elapsed }

  public var body: some View {
    elapsed
      .font(.system(size: 32, weight: .medium, design: .rounded).monospacedDigit())
      .foregroundStyle(.white)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
  }
}

public struct SleepActivityExpandedBottomView: View {
  public let startedAt: Date

  public init(startedAt: Date) { self.startedAt = startedAt }

  public var body: some View {
    SleepActivitySinceView(startedAt: startedAt, onDarkBackground: true)
      .frame(maxWidth: .infinity)
  }
}
#endif
