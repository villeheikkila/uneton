#if os(iOS)
import SwiftUI

public enum SleepActivityPalette {
  public static let ink = Color(red: 0.08, green: 0.20, blue: 0.27)
  public static let blue = Color(red: 0.13, green: 0.39, blue: 0.56)
  public static let turquoise = Color(red: 0.13, green: 0.49, blue: 0.52)
  public static let softBlue = Color(red: 0.83, green: 0.94, blue: 0.97)
  public static let mutedInk = Color(red: 0.29, green: 0.42, blue: 0.49)
  public static let mutedOnDark = Color(red: 0.69, green: 0.74, blue: 0.79)
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
      .foregroundStyle(.white)
      .frame(width: diameter, height: diameter)
      .background(SleepActivityPalette.blue, in: .circle)
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
        .foregroundStyle(.white)
        .frame(width: diameter, height: diameter)
        .background(SleepActivityPalette.turquoise, in: .circle)
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
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(SleepActivityPalette.blue, in: .circle)
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
