import Observation
import SwiftUI
import UnetonCore
import WatchConnectivity

private enum WatchPalette {
    static let blue = Color(red: 0.35, green: 0.70, blue: 0.85)
    static let turquoise = Color(red: 0.35, green: 0.78, blue: 0.76)
}

@main
struct UnetonWatchApp: App {
    @State private var bridge = WatchBridge(snapshotFixture: WatchScreenshotFixture.current)

    var body: some Scene {
        WindowGroup {
            WatchDiaryView()
                .environment(bridge)
                .tint(WatchPalette.blue)
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
    var selectedChildID: Child.ID?

    var selectedChild: WatchDiaryChild? { snapshot.selectedChild(id: selectedChildID) }

    private let usesSnapshotFixture: Bool

    init(snapshotFixture: WatchDiarySnapshot? = nil) {
        usesSnapshotFixture = snapshotFixture != nil
        selectedChildID = UserDefaults.standard.string(forKey: "watch.selectedChildID").flatMap(Child.ID.init(uuidString:))
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

    func selectChild(_ id: Child.ID) {
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
            errorMessage = String(localized: LocalizedStringResource("locOpenUnetonOnYourIPhoneToContinue", defaultValue: "Open Uneton on your iPhone to continue.", comment: "Message in UnetonWatchApp: Open Uneton on your iPhone to continue."))
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
                        self.errorMessage = String(localized: LocalizedStringResource("locCouldNotReadTheIPhoneReplyRetryTheAction", defaultValue: "Could not read the iPhone reply. Retry the action.", comment: "Message in UnetonWatchApp: Could not read the iPhone reply. Retry the action."))
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
                    self?.errorMessage = String(localized: LocalizedStringResource("locIPhoneDidNotReplyRetryTheAction", defaultValue: "iPhone did not reply. Retry the action.", comment: "Message in UnetonWatchApp: iPhone did not reply. Retry the action."))
                }
            })
        } catch {
            errorMessage = String(localized: LocalizedStringResource("locUnexpectedError", defaultValue: "Something went wrong. Try again.", comment: "Generic fallback for an unexpected error whose technical details may be untranslated"))
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
        let family = ModelFixtures.family()
        let child = ModelFixtures.child()
        return WatchDiarySnapshot(children: [ModelFixtures.watchChild(
            from: child, family: family,
            activeSleepStartedAt: scenario == "sleeping" ? .now.addingTimeInterval(-3_600) : nil,
            readings: scenario == "temperature" ? [ModelFixtures.temperature()] : []
        )])
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
                        .foregroundStyle(child.activeSleepStartedAt == nil ? WatchPalette.turquoise : WatchPalette.blue)
                    if let startedAt = child.activeSleepStartedAt {
                        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                            .font(.title3.monospacedDigit())
                    } else {
                        Text("locAwake", comment: "Text in UnetonWatchApp: Awake").font(.headline)
                    }
                    Button(child.activeSleepStartedAt == nil ? LocalizedStringResource("locStartSleep", defaultValue: "Start sleep", comment: "Button title in UnetonWatchApp: Start sleep") : LocalizedStringResource("locWakeUp", defaultValue: "Wake up", comment: "Action in Watch and Live Activity that records that the baby woke up")) {
                        bridge.send(WatchDiaryRequest(
                            action: child.activeSleepStartedAt == nil ? .startSleep : .endSleep,
                            familyID: child.familyID, childID: child.id))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(child.activeSleepStartedAt == nil ? WatchPalette.blue : WatchPalette.turquoise)
                    .disabled(bridge.isWorking || bridge.pendingRequest != nil)

                    Divider()
                    Button { showingNewTemperature = true } label: {
                        Label(LocalizedStringResource("locLogTemperature", defaultValue: "Log temperature", comment: "Label in UnetonWatchApp: Log temperature"), systemImage: "thermometer.medium")
                    }
                    .disabled(bridge.isWorking || bridge.pendingRequest != nil)
                    ForEach(child.readings) { reading in
                        Button {
                            editingReading = reading
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(String(format: "%.2f °C", locale: .current, Double(reading.centiCelsius) / 100))
                                        .font(.headline.monospacedDigit())
                                    Text(reading.measuredAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption2)
                                    if reading.isPending { Text("locSyncPending", comment: "Text in UnetonWatchApp: Sync pending").font(.caption2) }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2)
                            }
                        }
                        .disabled(bridge.isWorking || bridge.pendingRequest != nil)
                    }
                } else {
                    ContentUnavailableView(LocalizedStringResource("locSetUpUnetonOnIPhone", defaultValue: "Set up Uneton on iPhone", comment: "Text in UnetonWatchApp: Set up Uneton on iPhone"), systemImage: "iphone")
                }

                if let error = bridge.errorMessage {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
                if let notice = bridge.notice {
                    Text(notice).font(.caption2).foregroundStyle(.secondary)
                }
                if bridge.pendingRequest != nil && !bridge.isWorking {
                    Button(LocalizedStringResource("locRetryLastAction", defaultValue: "Retry last action", comment: "Button title in UnetonWatchApp: Retry last action")) { bridge.retry() }
                }
                Button(LocalizedStringResource("locRefresh", defaultValue: "Refresh", comment: "Button title in UnetonWatchApp: Refresh")) { bridge.refresh() }
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
                    Button(.locWatchChildOption(option.nickname, option.familyName)) {
                        bridge.selectChild(option.id)
                        showingChildPicker = false
                    }
                }
                .navigationTitle(LocalizedStringResource("locChooseChild", defaultValue: "Choose child", comment: "Screen title in UnetonWatchApp: Choose child"))
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
    @State private var newReadingID = TemperatureReading.ID()
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
                TextField(LocalizedStringResource("locTemperatureWatchUnit", defaultValue: "Temperature °C", comment: "Text field placeholder in UnetonWatchApp: Temperature °C"), text: $temperature)
                DatePicker(LocalizedStringResource("locMeasured", defaultValue: "Measured", comment: "Picker title in UnetonWatchApp: Measured"), selection: $measuredAt, in: ...Date.now)
                TextField(LocalizedStringResource("locNoteOptional", defaultValue: "Note (optional)", comment: "Text field placeholder in UnetonWatchApp: Note (optional)"), text: $note)
                if let reading {
                    Button(LocalizedStringResource("locDeleteReading", defaultValue: "Delete reading", comment: "Button title in UnetonWatchApp: Delete reading"), role: .destructive) {
                        send(WatchDiaryRequest(action: .deleteTemperature, familyID: child.familyID,
                            childID: child.id, readingID: reading.id, expectedRevision: reading.revision))
                        dismiss()
                    }
                }
            }
            .navigationTitle(reading == nil ? LocalizedStringResource("locTemperature", defaultValue: "Temperature", comment: "Temperature tracking tab or Watch screen title; this is body temperature") : LocalizedStringResource("locEditReading", defaultValue: "Edit reading", comment: "Screen title in UnetonWatchApp: Edit reading"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource("locSave", defaultValue: "Save", comment: "Button title in UnetonWatchApp: Save")) {
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
