import ComposableArchitecture2
import Foundation

struct SessionFamilyClient: Sendable {
    var createChildFamily: @MainActor @Sendable (String, Date, String) async -> String?
    var handleInvitation: @MainActor @Sendable (URL) async -> String?

    @MainActor
    static func live(session: SessionStore) -> Self {
        Self(
            createChildFamily: { childName, birthDate, growthReference in
                await session.createChildFamily(
                    childName: childName,
                    birthDate: birthDate,
                    growthReference: growthReference
                )
                return session.errorMessage
            },
            handleInvitation: { url in
                await session.handle(url: url)
                return session.errorMessage
            }
        )
    }

    static let unimplemented = Self(
        createChildFamily: { _, _, _ in fatalError("SessionFamilyClient.createChildFamily is not configured") },
        handleInvitation: { _ in fatalError("SessionFamilyClient.handleInvitation is not configured") }
    )
}

nonisolated extension FeatureEnvironmentValues {
    @FeatureEnvironmentEntry(
        liveValue: SessionFamilyClient.unimplemented,
        previewValue: SessionFamilyClient.unimplemented
    )
    var sessionFamily = SessionFamilyClient.unimplemented
}
