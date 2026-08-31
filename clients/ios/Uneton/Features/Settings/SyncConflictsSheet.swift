import Foundation
import UnetonCore
import SQLiteData
import SwiftUI

struct SyncConflictsSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @FetchAll(SyncConflict.order { $0.createdAt.desc() }) private var allConflicts
    let family: Family

    private var conflicts: [SyncConflict] {
        allConflicts.filter { $0.familyID == family.id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if conflicts.isEmpty {
                    ContentUnavailableView(
                        "All changes reconciled",
                        systemImage: "checkmark.circle",
                        description: Text("There are no changes that need your decision.")
                    )
                } else {
                    List(conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 12) {
                            Label(title(for: conflict), systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                                .font(.headline)
                            Text(conflict.reason)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Another caregiver changed this record before your offline change reached the server.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let comparison = SleepConflictComparison(conflict: conflict) {
                                VStack(spacing: 8) {
                                    ConflictVersionRow(
                                        title: "My change",
                                        startedAt: comparison.local.startedAt,
                                        endedAt: comparison.local.endedAt,
                                        tint: .indigo
                                    )
                                    ConflictVersionRow(
                                        title: "Server version",
                                        startedAt: comparison.server.startedAt,
                                        endedAt: comparison.server.endedAt,
                                        tint: .orange
                                    )
                                }
                            }
                            HStack {
                                Button("Use server version") {
                                    resolve(conflict, as: .keepServer)
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                                Button("Keep my change") {
                                    resolve(conflict, as: .keepMine)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Sync conflicts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func resolve(_ conflict: SyncConflict, as resolution: SyncConflictResolution) {
        Task {
            await session.resolveConflict(conflict.id, familyID: family.id, resolution: resolution)
            if conflicts.count == 1 { dismiss() }
        }
    }

    private func title(for conflict: SyncConflict) -> String {
        switch conflict.commandKind {
        case "upsertSleep", "endSleep": "Sleep time changed in two places"
        case "deleteSleep": "Sleep was edited and deleted"
        default: "Change needs review"
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
                Text("Sleeping")
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
