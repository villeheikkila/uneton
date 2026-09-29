import ComposableArchitecture2
import Foundation
import UnetonCore
import SwiftUI

struct SyncConflictsContent: View {
    let conflicts: [SyncConflict]
    let syncStore: StoreOf<FamilySync>

    var body: some View {
        Group {
            if conflicts.isEmpty {
                ContentUnavailableView(
                    LocalizedStringResource("locAllChangesReconciled", defaultValue: "All changes reconciled", comment: "Text in Timeline: All changes reconciled"),
                    systemImage: "checkmark.circle",
                    description: Text("locThereAreNoChangesThatNeedYourDecision", comment: "Text in Timeline: There are no changes that need your decision.")
                )
            } else {
                List(conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 12) {
                        Label(title(for: conflict), systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.headline)
                        Text(conflict.reason == "stale revision"
                            ? LocalizedStringResource("locAnotherCaregiverChangedThisRecordBeforeYourOfflineChangeReachedTheServer", defaultValue: "Another caregiver changed this record before your offline change reached the server.", comment: "Text in Timeline: Another caregiver changed this record before your offline change reached the server.")
                            : LocalizedStringResource("locThisChangeCouldNotBeAppliedReviewBothVersionsBeforeDeciding", defaultValue: "This change could not be applied. Review both versions before deciding.", comment: "Text in Timeline: This change could not be applied. Review both versions before deciding."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let comparison = SleepConflictComparison(conflict: conflict) {
                            VStack(spacing: 8) {
                                ConflictVersionRow(
                                    title: String(localized: LocalizedStringResource("locMyChange", defaultValue: "My change", comment: "Message in Timeline: My change")),
                                    startedAt: comparison.local.startedAt,
                                    endedAt: comparison.local.endedAt,
                                    tint: .indigo
                                )
                                ConflictVersionRow(
                                    title: String(localized: LocalizedStringResource("locServerVersion", defaultValue: "Server version", comment: "Message in Timeline: Server version")),
                                    startedAt: comparison.server.startedAt,
                                    endedAt: comparison.server.endedAt,
                                    tint: .orange
                                )
                            }
                        }
                        HStack {
                            Button(LocalizedStringResource("locUseServerVersion", defaultValue: "Use server version", comment: "Button title in Timeline: Use server version")) {
                                resolve(conflict, as: .keepServer)
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            Button(LocalizedStringResource("locKeepMyChange", defaultValue: "Keep my change", comment: "Button title in Timeline: Keep my change")) {
                                resolve(conflict, as: .keepMine)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func resolve(_ conflict: SyncConflict, as resolution: SyncConflictResolution) {
        syncStore.send(.resolveConflictButtonTapped(conflict.id, resolution))
    }

    private func title(for conflict: SyncConflict) -> String {
        switch conflict.commandKind {
        case "upsertSleep", "endSleep": String(localized: LocalizedStringResource("locSleepTimeChangedInTwoPlaces", defaultValue: "Sleep time changed in two places", comment: "Message in Timeline: Sleep time changed in two places"))
        case "deleteSleep": String(localized: LocalizedStringResource("locSleepWasEditedAndDeleted", defaultValue: "Sleep was edited and deleted", comment: "Message in Timeline: Sleep was edited and deleted"))
        default: String(localized: LocalizedStringResource("locChangeNeedsReview", defaultValue: "Change needs review", comment: "Message in Timeline: Change needs review"))
        }
    }
}

private struct ConflictVersionRow: View {
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let tint: Color

    var body: some View {
        HStack {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(title).font(.caption.weight(.semibold))
            Spacer()
            Text(startedAt, format: .dateTime.hour().minute())
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let endedAt {
                Text(endedAt, format: .dateTime.hour().minute())
            } else {
                Text("locSleeping", comment: "Text in Timeline: Sleeping")
            }
        }
        .font(.caption.monospacedDigit())
        .padding(10)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 12))
    }
}

private struct SleepConflictComparison {
    struct Payload: Decodable {
        var startedAt: Date
        var endedAt: Date?
    }

    var local: Payload
    var server: Payload

    init?(conflict: SyncConflict) {
        guard conflict.entityType == "sleepSession", let serverData = conflict.serverPayloadJSON,
              let local = try? JSONDecoder.uneton.decode(Payload.self, from: conflict.localPayloadJSON),
              let server = try? JSONDecoder.uneton.decode(Payload.self, from: serverData)
        else { return nil }
        self.local = local
        self.server = server
    }
}
