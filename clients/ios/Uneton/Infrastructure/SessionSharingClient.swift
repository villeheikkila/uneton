import ComposableArchitecture2
import Foundation
import UnetonCore

struct SessionSharingClient: Sendable {
    var createInvite: @MainActor @Sendable (Family.ID) async -> (URL?, String?)
    var deleteAccount: @MainActor @Sendable () async -> (Bool, String?)
    var setLiveActivitiesEnabled: @MainActor @Sendable (Bool) async -> Void
    var setNotificationsEnabled: @MainActor @Sendable (Bool) async -> Void
    var setReminderLeadMinutes: @MainActor @Sendable (Int) async -> Void
    var signOut: @MainActor @Sendable () async -> (Bool, String?)

    @MainActor
    static func live(session: SessionStore) -> Self {
        Self(
            createInvite: { familyID in
                session.errorMessage = nil
                let url = await session.createInvite(familyID: familyID)
                return (url, session.errorMessage)
            },
            deleteAccount: {
                let succeeded = await session.deleteAccount()
                return (succeeded, session.errorMessage)
            },
            setLiveActivitiesEnabled: { await session.setLiveActivitiesEnabled($0) },
            setNotificationsEnabled: { await session.setNotificationsEnabled($0) },
            setReminderLeadMinutes: { await session.setReminderLeadMinutes($0) },
            signOut: {
                let succeeded = await session.signOut()
                return (succeeded, session.errorMessage)
            }
        )
    }

    static let unimplemented = Self(
        createInvite: { _ in fatalError("SessionSharingClient.createInvite is not configured") },
        deleteAccount: { fatalError("SessionSharingClient.deleteAccount is not configured") },
        setLiveActivitiesEnabled: { _ in fatalError("SessionSharingClient.setLiveActivitiesEnabled is not configured") },
        setNotificationsEnabled: { _ in fatalError("SessionSharingClient.setNotificationsEnabled is not configured") },
        setReminderLeadMinutes: { _ in fatalError("SessionSharingClient.setReminderLeadMinutes is not configured") },
        signOut: { fatalError("SessionSharingClient.signOut is not configured") }
    )
}

nonisolated extension FeatureEnvironmentValues {
    @FeatureEnvironmentEntry(
        liveValue: SessionSharingClient.unimplemented,
        previewValue: SessionSharingClient.unimplemented
    )
    var sessionSharing = SessionSharingClient.unimplemented
}
