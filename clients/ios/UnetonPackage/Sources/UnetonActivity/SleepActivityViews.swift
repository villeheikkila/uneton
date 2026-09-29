#if os(iOS)
import SwiftUI

public enum SleepActivityPalette {
  public static let blue = Color(red: 0.13, green: 0.39, blue: 0.56)
  public static let softBlue = Color(red: 0.83, green: 0.94, blue: 0.97)
}

/// The lock-screen content is shared with visual tests; ActivityKit supplies its data and tint.
public struct SleepActivityLockScreenView: View {
  public let childName: String
  public let elapsed: Text
  public let endURL: URL

  public init(childName: String, elapsed: Text, endURL: URL) {
    self.childName = childName
    self.elapsed = elapsed
    self.endURL = endURL
  }

  public var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "moon.zzz.fill")
        .font(.title2)
        .foregroundStyle(SleepActivityPalette.blue)
      VStack(alignment: .leading, spacing: 3) {
        Text(.locChildIsSleeping(childName))
          .font(.headline)
        elapsed
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Spacer()
      Link(destination: endURL) {
        Text("locWakeUp", bundle: .module, comment: "Wake up ends the current sleep")
          .font(.subheadline.weight(.semibold))
          .padding(.horizontal, 13)
          .padding(.vertical, 9)
          .background(SleepActivityPalette.blue, in: .capsule)
          .foregroundStyle(.white)
      }
    }
    .padding()
  }
}

public struct SleepActivityExpandedCenterView: View {
  public let elapsed: Text

  public init(elapsed: Text) { self.elapsed = elapsed }

  public var body: some View {
    elapsed.font(.headline.monospacedDigit())
  }
}

public struct SleepActivityExpandedBottomView: View {
  public let childName: String

  public init(childName: String) { self.childName = childName }

  public var body: some View {
    Text(.locChildIsSleeping(childName))
      .foregroundStyle(.secondary)
  }
}
#endif
