import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import Uneton

/// References: Xcode 27.0 RC, iOS 26.5, iPhone 17 Pro, 402×874 points, 3×, arm64.
/// Use `mise run ios:snapshots:record` to deliberately replace references.
@Suite("Screen snapshots", .serialized)
@MainActor
struct ScreenSnapshots {
    private static let size = CGSize(width: 402, height: 874)

    @Test(arguments: ScreenFixtures.Scenario.allCases)
    func screen(_ scenario: ScreenFixtures.Scenario) async throws {
        try await capture(scenario)
    }

    private func capture(_ scenario: ScreenFixtures.Scenario) async throws {
        try await ScreenFixtures.seed(scenario)
        let controller = UIHostingController(rootView: ScreenFixtures.makeView(scenario))
        controller.overrideUserInterfaceStyle = .light
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.rootView = AnyView(EmptyView())
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        if scenario.hasSheet {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while controller.presentedViewController == nil && ContinuousClock.now < deadline {
                await Task.yield()
            }
            let presented = try #require(controller.presentedViewController, "Native sheet was not presented")
            #expect(presented.presentationController != nil)
        }
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(16))
            window.layoutIfNeeded()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: Self.size, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let strategy = Snapshotting<UIImage, UIImage>.image(
            precision: 0.98, perceptualPrecision: 0.90
        )
        #if UNETON_RECORD_SNAPSHOTS
            withKnownIssue("Explicit snapshot recording writes a reference") {
                assertSnapshot(of: image, as: strategy, named: scenario.rawValue, record: .all)
            }
        #else
            assertSnapshot(of: image, as: strategy, named: scenario.rawValue, record: .never)
        #endif
    }
}
