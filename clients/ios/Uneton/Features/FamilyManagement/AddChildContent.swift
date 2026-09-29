import ComposableArchitecture2
import SwiftUI

struct AddChildContent: View {
    @Bindable var store: StoreOf<FamilyManagement>
    var body: some View {
        Form {
            TextField("Baby’s name", text: $store.newChildName)
            DatePicker("Date of birth", selection: $store.newChildBirthDate,
                in: ...Date.now, displayedComponents: .date)
            Picker("Growth reference", selection: $store.newChildReference) {
                Text("None").tag("none")
                Text("Girl").tag("girl")
                Text("Boy").tag("boy")
            }
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
        }
    }
}
