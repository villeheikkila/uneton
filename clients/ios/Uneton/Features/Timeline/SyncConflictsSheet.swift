import ComposableArchitecture2
import UnetonCore
import SwiftUI

struct SyncConflictsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conflicts: [SyncConflict]
    let syncStore: StoreOf<FamilySync>

    var body: some View {
        NavigationStack {
            SyncConflictsContent(conflicts: conflicts, syncStore: syncStore)

                .navigationTitle(LocalizedStringResource("locSyncConflicts", defaultValue: "Sync conflicts", comment: "Screen title in Timeline: Sync conflicts"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button(LocalizedStringResource("locDone", defaultValue: "Done", comment: "Button title in Timeline: Done")) { dismiss() } }
            .overlay(alignment: .bottom) {
                if let error = syncStore.errorMessage {
                    Text(error).foregroundStyle(.red).padding()
                }
            }
        }
    }

}

#if DEBUG
#Preview("Sync conflicts sheet") { ScreenFixtures.preview(.syncConflictsSheet) }
#endif
