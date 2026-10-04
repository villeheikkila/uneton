import ComposableArchitecture2
import SwiftUI

struct ChildEditorContent: View {
    @Bindable var store: StoreOf<ChildEditor>
    var body: some View {
        Form {
            Section(LocalizedStringResource("locBaby", defaultValue: "Baby", comment: "Text in FamilyManagement: Baby")) {
                TextField(LocalizedStringResource("locNameOrNickname", defaultValue: "Name or nickname", comment: "Text field placeholder in FamilyManagement: Name or nickname"), text: $store.child.nickname)
                DatePicker(LocalizedStringResource("locDateOfBirth", defaultValue: "Date of birth", comment: "Picker title in FamilyManagement: Date of birth"), selection: $store.child.birthDate,
                    in: ...Date.now, displayedComponents: .date)
                Picker(LocalizedStringResource("locGrowthReference", defaultValue: "Growth reference", comment: "Picker title in FamilyManagement: Growth reference"), selection: $store.child.growthReference) {
                    Text("locNone", comment: "Text in FamilyManagement: None").tag("none")
                    Text("locGirl", comment: "Text in FamilyManagement: Girl").tag("girl")
                    Text("locBoy", comment: "Text in FamilyManagement: Boy").tag("boy")
                }
            }
            Section(LocalizedStringResource("locSleepPrediction", defaultValue: "Sleep prediction", comment: "Text in FamilyManagement: Sleep prediction")) {
                Picker(LocalizedStringResource("locMode", defaultValue: "Mode", comment: "Picker title in FamilyManagement: Mode"), selection: $store.child.predictionMode) {
                    Text("locAdaptiveEstimate", comment: "Text in FamilyManagement: Adaptive estimate").tag("adaptive")
                    Text("locManualInterval", comment: "Text in FamilyManagement: Manual interval").tag("manual")
                }
                if store.child.predictionMode == "manual" {
                    Picker(LocalizedStringResource("locTimeBetweenSleeps", defaultValue: "Time between sleeps", comment: "Picker title in FamilyManagement: Time between sleeps"), selection: $store.child.manualIntervalMinutes) {
                        ForEach([60, 90, 120, 150, 180, 210, 240], id: \.self) { minutes in
                            Text(.locMinutesCount(String(minutes))).tag(Optional(minutes))
                        }
                    }
                }
                Picker(LocalizedStringResource("locQuietHoursStart", defaultValue: "Quiet hours start", comment: "Picker title in FamilyManagement: Quiet hours start"), selection: $store.child.quietHoursStartMinutes) {
                    ForEach([1080, 1140, 1200, 1260, 1320, 1380], id: \.self) { minutes in
                        Text(String(format: "%02d:00", minutes / 60)).tag(minutes)
                    }
                }
                Picker(LocalizedStringResource("locQuietHoursEnd", defaultValue: "Quiet hours end", comment: "Picker title in FamilyManagement: Quiet hours end"), selection: $store.child.quietHoursEndMinutes) {
                    ForEach([300, 360, 420, 480, 540], id: \.self) { minutes in
                        Text(String(format: "%02d:00", minutes / 60)).tag(minutes)
                    }
                }
                LabeledContent(LocalizedStringResource("locTimeZone", defaultValue: "Time zone", comment: "Text in FamilyManagement: Time zone")) {
                    TextField(LocalizedStringResource("locAreaCity", defaultValue: "Area/City", comment: "Text field placeholder in FamilyManagement: Area/City"), text: $store.child.timeZone)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            Section {
                Button(LocalizedStringResource("locImportHuckleberry", defaultValue: "Import from Huckleberry", comment: "Choose a Huckleberry sleep-history CSV for this baby"), systemImage: "square.and.arrow.down") { store.send(.chooseImport) }
                    .disabled(store.request.isRunning || store.validationMessage != nil)
                Text("locImportExplanation", comment: "Explains sleep-only CSV import and time zone selection")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(store.child.timeZone).font(.footnote).foregroundStyle(.secondary)
                if let preview = store.importPreview {
                    Text(.locImportPreview(String(preview.sleeps.count), String(preview.ignoredRows)))
                    if let first = preview.sleeps.first, let last = preview.sleeps.last {
                        HStack {
                            Text(first.startedAt, format: .dateTime.year().month().day())
                            Text("–")
                            Text(last.endedAt, format: .dateTime.year().month().day())
                        }.font(.footnote).environment(\.timeZone, TimeZone(identifier: store.child.timeZone) ?? .current)
                    }
                    Button(LocalizedStringResource("locImportSleepRecords", defaultValue: "Import sleep records", comment: "Confirm importing the previewed CSV into this baby's diary")) { store.send(.confirmImport) }
                        .disabled(store.request.isRunning)
                }
                if store.request.isRunning { ProgressView() }
                if let message = store.importMessage { Text(message).foregroundStyle(.secondary) }
            }
            Section {
                Button(LocalizedStringResource("locDeleteBabyAndRecords", defaultValue: "Delete baby and records", comment: "Button title in FamilyManagement: Delete baby and records"), role: .destructive) { store.send(.promptDelete) }
            }
            if let validation = store.validationMessage {
                Section { Text(validation).foregroundStyle(.secondary) }
            }
            if let error = store.errorMessage { Section { Text(error).foregroundStyle(.red) } }
        }
        .disabled(store.request.isRunning)
    }
}
