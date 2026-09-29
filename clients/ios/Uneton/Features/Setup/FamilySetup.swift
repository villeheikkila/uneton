import ComposableArchitecture2
import Foundation
import Observation
import SQLiteData
import UnetonCore

@Feature
struct FamilySetup {
    struct State {
        @ObservationIgnored @DebugSnapshotIgnored @FetchOne(PendingCommand.count()) var pendingCommandCount = 0
        var birthDate = Calendar.current.date(byAdding: .month, value: -6, to: .now) ?? .now
        var childName = ""
        var errorMessage: String?
        var growthReference = "none"
        var isScanning = false
        @StoreTaskID var request
    }

    enum Action {
        case addBabyButtonTapped
        case invitationCodeScanned(String)
        case scanInvitationButtonTapped
    }

    @FeatureEnvironment(\.sessionFamily) private var sessionFamily

    var body: some Feature {
        Update { state, action in
            switch action {
            case .addBabyButtonTapped:
                let name = state.childName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let growthReference = state.growthReference
                let birthDate = state.birthDate
                state.errorMessage = nil
                store.addTask(id: state.request) {
                    let error = await sessionFamily.createChildFamily(name, birthDate, growthReference)
                    try store.modify { $0.errorMessage = error }
                }
            case let .invitationCodeScanned(code):
                state.isScanning = false
                guard let url = URL(string: code),
                      url.scheme == "uneton",
                      url.host == "invite",
                      url.pathComponents.dropFirst().first != nil else {
                    state.errorMessage = "Invalid family invitation"
                    return
                }
                state.errorMessage = nil
                store.addTask(id: state.request) {
                    let error = await sessionFamily.handleInvitation(url)
                    try store.modify { $0.errorMessage = error }
                }
            case .scanInvitationButtonTapped:
                state.isScanning = true
            }
        }
    }
}
