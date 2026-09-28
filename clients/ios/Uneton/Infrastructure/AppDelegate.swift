import BackgroundTasks
import Foundation
import UIKit
import UserNotifications
import UnetonCore

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let refreshIdentifier = "solutions.bytesized.uneton.refresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard !AppMode.isDemo else { return true }
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
        guard let value = userInfo["familyID"] as? String, let familyID = Family.ID(uuidString: value) else {
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
