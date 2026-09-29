import ComposableArchitecture2
import SwiftUI

struct ChildEditorContent: View {
    @Bindable var store: StoreOf<ChildEditor>
    var body: some View {
        Form {
            Section("Baby") {
                TextField("Name or nickname", text: $store.child.nickname)
                DatePicker("Date of birth", selection: $store.child.birthDate,
                    in: ...Date.now, displayedComponents: .date)
                Picker("Growth reference", selection: $store.child.growthReference) {
                    Text("None").tag("none")
                    Text("Girl").tag("girl")
                    Text("Boy").tag("boy")
                }
            }
            Section("Sleep prediction") {
                Picker("Mode", selection: $store.child.predictionMode) {
                    Text("Adaptive estimate").tag("adaptive")
                    Text("Manual interval").tag("manual")
                }
                if store.child.predictionMode == "manual" {
                    Picker("Time between sleeps", selection: $store.child.manualIntervalMinutes) {
                        ForEach([60, 90, 120, 150, 180, 210, 240], id: \.self) { minutes in
                            Text("\(minutes) minutes").tag(Optional(minutes))
                        }
                    }
                }
                Picker("Quiet hours start", selection: $store.child.quietHoursStartMinutes) {
                    ForEach([1080, 1140, 1200, 1260, 1320, 1380], id: \.self) { minutes in
                        Text(String(format: "%02d:00", minutes / 60)).tag(minutes)
                    }
                }
                Picker("Quiet hours end", selection: $store.child.quietHoursEndMinutes) {
                    ForEach([300, 360, 420, 480, 540], id: \.self) { minutes in
                        Text(String(format: "%02d:00", minutes / 60)).tag(minutes)
                    }
                }
                LabeledContent("Time zone") {
                    TextField("Area/City", text: $store.child.timeZone)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            Section {
                Button("Delete baby and records", role: .destructive) { store.send(.promptDelete) }
            }
            if let validation = store.validationMessage {
                Section { Text(validation).foregroundStyle(.secondary) }
            }
            if let error = store.errorMessage { Section { Text(error).foregroundStyle(.red) } }
        }
    }
}
