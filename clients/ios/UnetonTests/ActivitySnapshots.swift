import SnapshotTesting
import SwiftUI
import Testing
import UIKit
import UnetonActivity

/// Renders the same content views used by ActivityKit with a fixed elapsed label.
@Suite("Live Activity snapshots", .serialized)
@MainActor
struct ActivitySnapshots {
    private var startedAt: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 20, minute: 28))!
    }

    private var endURL: URL {
        URL(string: "uneton://sleep/end?familyID=1&sessionID=2")!
    }

    @Test func lockScreen() throws {
        let content = SleepActivityLockScreenView(
            childName: "Aino", startedAt: startedAt, elapsed: Text("1:58:16"), endURL: endURL
        )
        .frame(width: 402, height: 112)
        .background(SleepActivityPalette.cardBackground, in: .rect(cornerRadius: 26))
        try capture(content, size: CGSize(width: 402, height: 112), name: "lockScreen")
    }

    @Test func expandedIsland() throws {
        let content = VStack(spacing: 3) {
            HStack(spacing: 8) {
                SleepActivityIdentityView(childName: "Aino", diameter: 42)
                Spacer(minLength: 0)
                SleepActivityExpandedCenterView(elapsed: Text("1:58:16"))
                Spacer(minLength: 0)
                SleepActivityWakeLink(endURL: endURL, diameter: 42)
            }
            SleepActivityExpandedBottomView(startedAt: startedAt)
        }
        .padding(.horizontal, 12)
        .frame(width: 350, height: 112)
        .background(.black)
        try capture(content, size: CGSize(width: 350, height: 112), name: "expandedIsland")
    }

    private func capture<V: View>(_ view: V, size: CGSize, name: String) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view.ignoresSafeArea().environment(\.locale, Locale(identifier: "en_GB")))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let strategy = Snapshotting<UIImage, UIImage>.image(precision: 0.98, perceptualPrecision: 0.90)
        #if UNETON_RECORD_SNAPSHOTS
            withKnownIssue("Explicit snapshot recording writes a reference") {
                assertSnapshot(of: image, as: strategy, named: name, record: .all)
            }
        #else
            assertSnapshot(of: image, as: strategy, named: name, record: .never)
        #endif
    }
}
