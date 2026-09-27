import Foundation
import SwiftUI

private struct DisplayNowKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    var unetonDisplayNow: Date? {
        get { self[DisplayNowKey.self] }
        set { self[DisplayNowKey.self] = newValue }
    }
}
