import Observation
import SwiftUI
import UnetonCore
import WatchConnectivity

@main
struct UnetonWatchApp: App {
    @State private var bridge = WatchBridge(snapshotFixture: WatchScreenshotFixture.current)

    var body: some Scene {
        WindowGroup {
            WatchDiaryView()
                .environment(bridge)
        }
    }
}

@MainActor
@Observable
final class WatchBridge: NSObject, WCSessionDelegate {
    private(set) var snapshot = WatchDiarySnapshot()
    private(set) var isWorking = false
    private(set) var pendingRequest: WatchDiaryRequest?
    var errorMessage: String?
    var notice: String?
    var selectedChildID: UUID?

    var selectedChild: WatchDiaryChild? { snapshot.selectedChild(id: selectedChildID) }

    private let usesSnapshotFixture: Bool

    init(snapshotFixture: WatchDiarySnapshot? = nil) {
        usesSnapshotFixture = snapshotFixture != nil
        selectedChildID = UserDefaults.standard.string(forKey: "watch.selectedChildID").flatMap(UUID.init(uuidString:))
        super.init()
        if let snapshotFixture {
            snapshot = snapshotFixture
            selectedChildID = snapshotFixture.children.first?.id
            return
        }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func selectChild(_ id: UUID) {
        selectedChildID = id
        UserDefaults.standard.set(id.uuidString, forKey: "watch.selectedChildID")
    }

    private func accept(_ value: WatchDiarySnapshot) {
        snapshot = value
        if value.children.isEmpty {
            selectedChildID = nil
            UserDefaults.standard.removeObject(forKey: "watch.selectedChildID")
        } else if value.children.contains(where: { $0.id == selectedChildID }) == false,
                  let first = value.children.first {
            selectChild(first.id)
        }
    }

    func refresh() {
        guard !usesSnapshotFixture else { return }
        guard pendingRequest == nil else { return }
        send(WatchDiaryRequest(action: .status))
    }

    func retry() {
        guard let pendingRequest else { return }
        send(pendingRequest)
    }

    func send(_ request: WatchDiaryRequest) {
        guard !isWorking else { return }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isReachable else {
            if request.action != .status { pendingRequest = request }
            errorMessage = "Open Uneton on your iPhone to continue."
            return
        }
        do {
            let data = try JSONEncoder().encode(request)
            if request.action != .status { pendingRequest = request }
            isWorking = true
            errorMessage = nil
            notice = nil
            WCSession.default.sendMessageData(data, replyHandler: { [weak self] data in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isWorking = false
                    guard let response = try? JSONDecoder().decode(WatchDiaryResponse.self, from: data) else {
                        self.errorMessage = "Could not read the iPhone reply. Retry the action."
                        return
                    }
                    self.accept(response.snapshot)
                    self.errorMessage = response.errorMessage
                    self.notice = response.notice
                    self.pendingRequest = nil
                }
            }, errorHandler: { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isWorking = false
                    self?.errorMessage = "iPhone did not reply. Retry the action."
                }
            })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let cached = (session.receivedApplicationContext["watchDiarySnapshot"] as? Data)
            .flatMap { try? JSONDecoder().decode(WatchDiarySnapshot.self, from: $0) }
        Task { @MainActor [weak self] in
            if let cached { self?.accept(cached) }
            self?.refresh()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["watchDiarySnapshot"] as? Data,
              let snapshot = try? JSONDecoder().decode(WatchDiarySnapshot.self, from: data) else { return }
        Task { @MainActor [weak self] in self?.accept(snapshot) }
    }
}

#if DEBUG
private enum WatchScreenshotFixture {
    static var current: WatchDiarySnapshot? {
        guard let scenario = ProcessInfo.processInfo.environment["UNETON_WATCH_SCREENSHOT_SCENARIO"] else {
            return nil
        }
        let familyID = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
        let childID = UUID(uuidString: "00000000-0000-4000-8000-000000000102")!
        let reading = WatchDiaryReading(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000103")!,
            measuredAt: Date(timeIntervalSince1970: 1_790_000_000),
            centiCelsius: 3820, note: "After nap", revision: 1, isPending: false)
        let child = WatchDiaryChild(
            id: childID, familyID: familyID, familyName: "Our family", nickname: "Aino",
            activeSleepStartedAt: scenario == "sleeping" ? .now.addingTimeInterval(-3600) : nil,
            readings: scenario == "temperature" ? [reading] : [])
        return WatchDiarySnapshot(children: [child])
    }
}
#else
private enum WatchScreenshotFixture {
    static var current: WatchDiarySnapshot? { nil }
}
#endif

private struct WatchDiaryView: View {
    @Environment(WatchBridge.self) private var bridge
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingNewTemperature = false
    @State private var showingChildPicker = false
    @State private var editingReading: WatchDiaryReading?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let child = bridge.selectedChild {
                    if bridge.snapshot.children.count > 1 {
                        Button { showingChildPicker = true } label: {
                            Label(child.nickname, systemImage: "person.2")
                        }
                    } else {
                        Text(child.nickname).font(.headline)
                    }

                    Image(systemName: child.activeSleepStartedAt == nil ? "sun.max.fill" : "moon.zzz.fill")
                        .font(.largeTitle)
                        .foregroundStyle(child.activeSleepStartedAt == nil ? .orange : .indigo)
                    if let startedAt = child.activeSleepStartedAt {
                        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                            .font(.title3.monospacedDigit())
                    } else {
                        Text("Awake").font(.headline)
                    }
                    Button(child.activeSleepStartedAt == nil ? "Start sleep" : "Wake up") {
                        bridge.send(WatchDiaryRequest(
                            action: child.activeSleepStartedAt == nil ? .startSleep : .endSleep,
                            familyID: child.familyID, childID: child.id))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(child.activeSleepStartedAt == nil ? .indigo : .orange)
                    .disabled(bridge.isWorking || bridge.pendingRequest != nil)

                    Divider()
                    Button { showingNewTemperature = true } label: {
                        Label("Log temperature", systemImage: "thermometer.medium")
                    }
                    .disabled(bridge.isWorking || bridge.pendingRequest != nil)
                    ForEach(child.readings) { reading in
                        Button {
                            editingReading = reading
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(String(format: "%.2f °C", Double(reading.centiCelsius) / 100))
                                        .font(.headline.monospacedDigit())
                                    Text(reading.measuredAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption2)
                                    if reading.isPending { Text("Sync pending").font(.caption2) }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2)
                            }
                        }
                        .disabled(bridge.isWorking || bridge.pendingRequest != nil)
                    }
                } else {
                    ContentUnavailableView("Set up Uneton on iPhone", systemImage: "iphone")
                }

                if let error = bridge.errorMessage {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
                if let notice = bridge.notice {
                    Text(notice).font(.caption2).foregroundStyle(.secondary)
                }
                if bridge.pendingRequest != nil && !bridge.isWorking {
                    Button("Retry last action") { bridge.retry() }
                }
                Button("Refresh") { bridge.refresh() }
                    .disabled(bridge.isWorking || bridge.pendingRequest != nil)
                    .font(.caption)
            }
            .padding()
        }
        .task { bridge.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { bridge.refresh() } }
        .sheet(isPresented: $showingNewTemperature) {
            if let child = bridge.selectedChild {
                WatchTemperatureSheet(child: child, reading: nil) { bridge.send($0) }
            }
        }
        .sheet(isPresented: $showingChildPicker) {
            NavigationStack {
                List(bridge.snapshot.children) { option in
                    Button("\(option.nickname) · \(option.familyName)") {
                        bridge.selectChild(option.id)
                        showingChildPicker = false
                    }
                }
                .navigationTitle("Choose child")
            }
        }
        .sheet(item: $editingReading) { reading in
            if let child = bridge.selectedChild {
                WatchTemperatureSheet(child: child, reading: reading) { bridge.send($0) }
            }
        }
    }
}

private struct WatchTemperatureSheet: View {
    @Environment(\.dismiss) private var dismiss
    let child: WatchDiaryChild
    let reading: WatchDiaryReading?
    let send: (WatchDiaryRequest) -> Void
    @State private var newReadingID = UUID()
    @State private var measuredAt: Date
    @State private var temperature: String
    @State private var note: String

    init(child: WatchDiaryChild, reading: WatchDiaryReading?, send: @escaping (WatchDiaryRequest) -> Void) {
        self.child = child
        self.reading = reading
        self.send = send
        _measuredAt = State(initialValue: reading?.measuredAt ?? .now)
        _temperature = State(initialValue: reading.map { String(format: "%.2f", Double($0.centiCelsius) / 100) } ?? "")
        _note = State(initialValue: reading?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Temperature °C", text: $temperature)
                DatePicker("Measured", selection: $measuredAt, in: ...Date.now)
                TextField("Note (optional)", text: $note)
                if let reading {
                    Button("Delete reading", role: .destructive) {
                        send(WatchDiaryRequest(action: .deleteTemperature, familyID: child.familyID,
                            childID: child.id, readingID: reading.id, expectedRevision: reading.revision))
                        dismiss()
                    }
                }
            }
            .navigationTitle(reading == nil ? "Temperature" : "Edit reading")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let centiCelsius = TemperatureValue.centiCelsius(from: temperature) else { return }
                        send(WatchDiaryRequest(action: .upsertTemperature, familyID: child.familyID,
                            childID: child.id, readingID: reading?.id ?? newReadingID,
                            expectedRevision: reading?.revision, isNewReading: reading == nil,
                            measuredAt: measuredAt, centiCelsius: centiCelsius,
                            note: note.trimmingCharacters(in: .whitespacesAndNewlines)))
                        dismiss()
                    }
                    .disabled(TemperatureValue.centiCelsius(from: temperature) == nil)
                }
            }
        }
    }
}
