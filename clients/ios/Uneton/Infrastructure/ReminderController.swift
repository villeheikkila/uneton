import Foundation
import UnetonCore
import UserNotifications

struct ReminderController: Sendable {
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func schedule(fireDate: Date?) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["next-sleep"])
        guard let fireDate else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: LocalizedStringResource("locSleepWindowIsApproaching", defaultValue: "Sleep window is approaching", comment: "Message in ReminderController: Sleep window is approaching"))
        content.body = String(localized: LocalizedStringResource("locYourBabyMayBeReadyForSleepSoon", defaultValue: "Your baby may be ready for sleep soon.", comment: "Brief sleep reminder; the server's explanation is not localized"))
        content.sound = .default
        try? await center.add(UNNotificationRequest(
            identifier: "next-sleep",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireDate.timeIntervalSinceNow), repeats: false)
        ))
    }
}
