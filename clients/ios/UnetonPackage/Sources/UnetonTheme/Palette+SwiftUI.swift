#if canImport(SwiftUI)
import SwiftUI

extension RGBColor {
  public var color: Color {
    Color(.sRGB, red: red, green: green, blue: blue)
  }
}
#endif
