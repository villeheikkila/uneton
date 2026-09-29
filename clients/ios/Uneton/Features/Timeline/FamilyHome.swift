import ComposableArchitecture2
import Observation
import SQLiteData
import UnetonCore

@Feature
struct FamilyHome {
    struct State {
        let familyID: Family.ID
        @ObservationIgnored @DebugSnapshotIgnored @FetchAll var children: [Child]

        init(familyID: Family.ID) {
            self.familyID = familyID
            _children = FetchAll(Child.where { $0.familyID.eq(familyID) }
                .order { $0.updatedAt.desc() })
        }

        var isLoadingChildren: Bool { $children.isLoading }
    }
}
