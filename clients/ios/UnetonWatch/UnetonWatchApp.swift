import SwiftUI
import WatchConnectivity
import Observation

@main
struct UnetonWatchApp: App {
    @State private var bridge = WatchBridge()

    var body: some Scene {
        WindowGroup {
            WatchSleepView()
                .environment(bridge)
        }
    }
}

@MainActor
@Observable
final class WatchBridge: NSObject, WCSessionDelegate {
    var isSleeping = false
    var startedAt: Date?
    var errorMessage: String?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func toggle() {
        let action = isSleeping ? "endSleep" : "startSleep"
        WCSession.default.sendMessage(["action": action], replyHandler: { [weak self] reply in
            Task { @MainActor in
                self?.isSleeping = reply["isSleeping"] as? Bool ?? !self!.isSleeping
                self?.startedAt = reply["startedAt"] as? Date
                self?.errorMessage = nil
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in self?.errorMessage = error.localizedDescription }
        })
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {}
}

struct WatchSleepView: View {
    @Environment(WatchBridge.self) private var bridge

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: bridge.isSleeping ? "moon.zzz.fill" : "sun.max.fill")
                .font(.largeTitle)
                .foregroundStyle(bridge.isSleeping ? .indigo : .orange)
            if let startedAt = bridge.startedAt, bridge.isSleeping {
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(.title3.monospacedDigit())
            } else {
                Text("Ready for sleep")
                    .font(.headline)
            }
            Button(bridge.isSleeping ? "Wake up" : "Start sleep") {
                bridge.toggle()
            }
            .buttonStyle(.borderedProminent)
            .tint(bridge.isSleeping ? .orange : .indigo)
            if let error = bridge.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding()
    }
}
