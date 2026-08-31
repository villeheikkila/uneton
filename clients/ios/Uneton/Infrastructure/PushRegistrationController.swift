import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    static let unetonAPNSTokenChanged = Notification.Name("unetonAPNSTokenChanged")
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let refreshIdentifier = "solutions.bytesized.uneton.refresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: .main) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.performAppRefresh(refreshTask)
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleAppRefresh()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .unetonAPNSTokenChanged, object: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // APNs registration is retried on the next application launch.
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let value = userInfo["familyID"] as? String, let familyID = UUID(uuidString: value) else {
            completionHandler(.noData)
            return
        }
        Task {
            let refreshed = await PushRegistrationController.refresh(familyID: familyID)
            completionHandler(refreshed ? .newData : .failed)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func performAppRefresh(_ task: BGAppRefreshTask) {
        scheduleAppRefresh()
        let operation = Task {
            let refreshed = await PushRegistrationController.refreshAll()
            guard !Task.isCancelled else { return }
            task.setTaskCompleted(success: refreshed)
        }
        task.expirationHandler = { operation.cancel() }
    }
}

@MainActor
enum PushRegistrationController {
    private static var familyRefresh: ((UUID) async -> Bool)?
    private static var allRefresh: (() async -> Bool)?

    static func installBackgroundRefresh(
        family: @escaping (UUID) async -> Bool,
        all: @escaping () async -> Bool
    ) {
        familyRefresh = family
        allRefresh = all
    }

    static func refresh(familyID: UUID) async -> Bool {
        await familyRefresh?(familyID) ?? false
    }

    static func refreshAll() async -> Bool {
        await allRefresh?() ?? false
    }

    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }

    static var environment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }
}

extension Data {
    var hexadecimalString: String { map { String(format: "%02x", $0) }.joined() }
}
