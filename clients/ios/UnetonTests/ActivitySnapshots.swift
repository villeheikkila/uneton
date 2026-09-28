import SnapshotTesting
import SwiftUI
import Testing
import UIKit
import UnetonActivity

/// Renders the same content views used by ActivityKit with a fixed elapsed label.
@Suite("Live Activity snapshots", .serialized)
@MainActor
struct ActivitySnapshots {
    @Test func lockScreen() throws {
        let content = SleepActivityLockScreenView(
            childName: "Aino", elapsed: Text("1:23:45"),
            endURL: URL(string: "uneton://sleep/end?familyID=1&sessionID=2")!
        )
        .frame(width: 402, height: 92)
        .background(Color.indigo.opacity(0.12))
        try capture(content, size: CGSize(width: 402, height: 92), name: "lockScreen")
    }

    @Test func expandedIsland() throws {
        let content = VStack(spacing: 8) {
            HStack {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
                Spacer()
                SleepActivityExpandedCenterView(elapsed: Text("1:23:45"))
                Spacer()
                Text("Wake").font(.caption.weight(.bold))
            }
            SleepActivityExpandedBottomView(childName: "Aino")
        }
        .padding(16)
        .frame(width: 350, height: 100)
        .background(.black)
        .foregroundStyle(.white)
        try capture(content, size: CGSize(width: 350, height: 100), name: "expandedIsland")
    }

    private func capture<V: View>(_ view: V, size: CGSize, name: String) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view.ignoresSafeArea())
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
