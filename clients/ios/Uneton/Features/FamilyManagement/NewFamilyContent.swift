import ComposableArchitecture2
import SwiftUI

struct NewFamilyContent: View {
    @Bindable var store: StoreOf<FamilyManagement>
    var body: some View {
        Form {
            TextField(LocalizedStringResource("locFamilyName", defaultValue: "Family name", comment: "Text field placeholder in FamilyManagement: Family name"), text: $store.newFamilyName)
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
        }
    }
}
