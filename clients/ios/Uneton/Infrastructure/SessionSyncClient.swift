import ComposableArchitecture2
import Foundation
import UnetonCore

struct SessionSyncClient: Sendable {
    var handleURL: @MainActor @Sendable (URL) async -> Void
    var isAuthenticated: @MainActor @Sendable () -> Bool
    var observe: @MainActor @Sendable (Family.ID) async -> Void
    var refresh: @MainActor @Sendable (Family.ID) async -> Void
    var validateCredential: @MainActor @Sendable () async -> Void

    @MainActor
    static func live(session: SessionStore) -> Self {
        Self(
            handleURL: { await session.handle(url: $0) },
            isAuthenticated: { session.isAuthenticated },
            observe: { await session.observeChanges(familyID: $0) },
            refresh: { await session.synchronize(familyID: $0) },
            validateCredential: { await session.validateAppleCredential() }
        )
    }

    static let unimplemented = Self(
        handleURL: { _ in fatalError("SessionSyncClient.handleURL is not configured") },
        isAuthenticated: { fatalError("SessionSyncClient.isAuthenticated is not configured") },
        observe: { _ in fatalError("SessionSyncClient.observe is not configured") },
        refresh: { _ in fatalError("SessionSyncClient.refresh is not configured") },
        validateCredential: { fatalError("SessionSyncClient.validateCredential is not configured") }
    )
}

nonisolated extension FeatureEnvironmentValues {
    @FeatureEnvironmentEntry(
        liveValue: SessionSyncClient.unimplemented,
        previewValue: SessionSyncClient.unimplemented
    )
    var sessionSync = SessionSyncClient.unimplemented
}
