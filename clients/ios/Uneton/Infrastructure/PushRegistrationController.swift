import Foundation
import UIKit
import UserNotifications
import UnetonCore

extension Notification.Name {
    static let unetonAPNSTokenChanged = Notification.Name("unetonAPNSTokenChanged")
}

@MainActor
enum PushRegistrationController {
    static var latestToken: Data?
    private static var familyRefresh: ((Family.ID) async -> Bool)?
    private static var allRefresh: (() async -> Bool)?

    static func installBackgroundRefresh(
        family: @escaping (Family.ID) async -> Bool,
        all: @escaping () async -> Bool
    ) {
        familyRefresh = family
        allRefresh = all
    }

    static func refresh(familyID: Family.ID) async -> Bool {
        await familyRefresh?(familyID) ?? false
    }

    static func refreshAll() async -> Bool {
        await allRefresh?() ?? false
    }

    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        register()
    }

    static func register() { UIApplication.shared.registerForRemoteNotifications() }

    static var environment: String {
        Bundle.main.object(forInfoDictionaryKey: "UnetonAPNSEnvironment") as? String ?? "development"
    }
}

extension Data {
    var hexadecimalString: String { map { String(format: "%02x", $0) }.joined() }
}
