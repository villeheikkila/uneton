import Foundation
import WatchConnectivity

final class PhoneWatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    weak var store: SessionStore?

    init(store: SessionStore) {
        self.store = store
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let action = message["action"] as? String else {
            replyHandler(["error": "Missing action"])
            return
        }
        let reply = SendableReply(replyHandler)
        Task { @MainActor [weak self] in
            guard let store = self?.store else {
                reply.call(["error": "Phone app unavailable"])
                return
            }
            let state = await store.handleWatchAction(action)
            var response: [String: Any] = ["isSleeping": state.isSleeping]
            if let startedAt = state.startedAt { response["startedAt"] = startedAt }
            if let error = state.error { response["error"] = error }
            reply.call(response)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}

private struct SendableReply: @unchecked Sendable {
    let call: ([String: Any]) -> Void
    init(_ call: @escaping ([String: Any]) -> Void) { self.call = call }
}
