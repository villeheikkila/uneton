import AuthenticationServices
import ComposableArchitecture2

struct SessionAuthClient: Sendable {
    var completeAppleAuthorization: @MainActor @Sendable (Result<ASAuthorization, any Error>) async -> String?
    var developmentAuthenticate: @MainActor @Sendable (String) async -> String?

    @MainActor
    static func live(session: SessionStore) -> Self {
        Self(
            completeAppleAuthorization: { result in
                await session.completeAppleAuthorization(result)
                return session.errorMessage
            },
            developmentAuthenticate: { name in
                await session.developmentAuthenticate(name: name)
                return session.errorMessage
            }
        )
    }

    static let unimplemented = Self(
        completeAppleAuthorization: { _ in fatalError("SessionAuthClient.completeAppleAuthorization is not configured") },
        developmentAuthenticate: { _ in fatalError("SessionAuthClient.developmentAuthenticate is not configured") }
    )
}

nonisolated extension FeatureEnvironmentValues {
    @FeatureEnvironmentEntry(
        liveValue: SessionAuthClient.unimplemented,
        previewValue: SessionAuthClient.unimplemented
    )
    var sessionAuth = SessionAuthClient.unimplemented
}
