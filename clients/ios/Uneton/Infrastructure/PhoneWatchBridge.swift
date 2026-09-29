import Foundation
import UnetonCore
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

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        let reply = SendableReply(replyHandler)
        Task { @MainActor [weak self] in
            guard let store = self?.store else {
                reply.call(Self.encoded(WatchDiaryResponse(snapshot: WatchDiarySnapshot(),
                    errorMessage: String(localized: LocalizedStringResource("locPhoneAppUnavailable", defaultValue: "Phone app unavailable", comment: "Message in PhoneWatchBridge: Phone app unavailable")),
                    retryable: true)))
                return
            }
            let request = try? JSONDecoder().decode(WatchDiaryRequest.self, from: messageData)
            guard let request else {
                let snapshot = (try? await store.watchDiarySnapshot()) ?? WatchDiarySnapshot()
                reply.call(Self.encoded(WatchDiaryResponse(snapshot: snapshot,
                    errorMessage: String(localized: LocalizedStringResource("locInvalidWatchRequest", defaultValue: "Invalid Watch request", comment: "Message in PhoneWatchBridge: Invalid Watch request")))))
                return
            }
            reply.call(Self.encoded(await store.handleWatchRequest(request)))
        }
    }

    @MainActor
    func publishSnapshot() async {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let store else { return }
        do {
            let data = try JSONEncoder().encode(try await store.watchDiarySnapshot())
            try WCSession.default.updateApplicationContext(["watchDiarySnapshot": data])
        } catch {
            // The next Watch status request reads the current phone projection.
        }
    }

    private static func encoded(_ response: WatchDiaryResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in await self?.publishSnapshot() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}

private struct SendableReply: @unchecked Sendable {
    let call: (Data) -> Void
    init(_ call: @escaping (Data) -> Void) { self.call = call }
}
