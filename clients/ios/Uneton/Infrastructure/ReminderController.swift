import Foundation
import UnetonCore
import UserNotifications

struct ReminderController: Sendable {
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func schedule(_ prediction: SleepPrediction?, leadMinutes: Int = 15) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["next-sleep"])
        guard let prediction else { return }
        let fireDate = prediction.targetAt.addingTimeInterval(-Double(leadMinutes) * 60)
        guard fireDate > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: LocalizedStringResource("locSleepWindowIsApproaching", defaultValue: "Sleep window is approaching", comment: "Message in ReminderController: Sleep window is approaching"))
        content.body = String(localized: LocalizedStringResource("locYourBabyMayBeReadyForSleepSoon", defaultValue: "Your baby may be ready for sleep soon.", comment: "Brief sleep reminder; the server's explanation is not localized"))
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        try? await center.add(UNNotificationRequest(
            identifier: "next-sleep",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        ))
    }
}
