import AuthenticationServices
import Foundation

struct AppleCredentialMonitor {
    enum Result: Equatable {
        case valid
        case revoked
        case skipped
        case unavailable
    }

    private static let lastCheckKey = "session.appleCredentialLastCheck"
    private static let minimumInterval: TimeInterval = 24 * 60 * 60

    func check(userID: String, force: Bool = false, now: Date = .now) async -> Result {
        let defaults = UserDefaults.standard
        if !force,
           let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date,
           now.timeIntervalSince(lastCheck) < Self.minimumInterval
        {
            return .skipped
        }
        do {
            let state = try await credentialState(for: userID)
            defaults.set(now, forKey: Self.lastCheckKey)
            switch state {
            case .authorized, .transferred:
                return .valid
            case .revoked, .notFound:
                return .revoked
            @unknown default:
                return .unavailable
            }
        } catch {
            // Offline checks must not invalidate an otherwise usable server session.
            return .unavailable
        }
    }

    private func credentialState(for userID: String) async throws -> ASAuthorizationAppleIDProvider.CredentialState {
        try await withCheckedThrowingContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: state)
                }
            }
        }
    }
}
