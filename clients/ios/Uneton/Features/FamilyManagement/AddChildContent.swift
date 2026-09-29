import ComposableArchitecture2
import SwiftUI

struct AddChildContent: View {
    @Bindable var store: StoreOf<FamilyManagement>
    var body: some View {
        Form {
            TextField(LocalizedStringResource("locBabySName", defaultValue: "Baby’s name", comment: "Text field placeholder in FamilyManagement: Baby’s name"), text: $store.newChildName)
            DatePicker(LocalizedStringResource("locDateOfBirth", defaultValue: "Date of birth", comment: "Picker title in FamilyManagement: Date of birth"), selection: $store.newChildBirthDate,
                in: ...Date.now, displayedComponents: .date)
            Picker(LocalizedStringResource("locGrowthReference", defaultValue: "Growth reference", comment: "Picker title in FamilyManagement: Growth reference"), selection: $store.newChildReference) {
                Text("locNone", comment: "Text in FamilyManagement: None").tag("none")
                Text("locGirl", comment: "Text in FamilyManagement: Girl").tag("girl")
                Text("locBoy", comment: "Text in FamilyManagement: Boy").tag("boy")
            }
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
        }
    }
}
