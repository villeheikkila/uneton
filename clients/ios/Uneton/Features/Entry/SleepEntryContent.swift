import ComposableArchitecture2
import SwiftUI

struct SleepEntryContent: View {
    @Bindable var store: StoreOf<SleepEntry>

    var body: some View {
        Form {
            Section(LocalizedStringResource("locStarted", defaultValue: "Started", comment: "Text in Entry: Started")) {
                Picker(LocalizedStringResource("locStarted", defaultValue: "Started", comment: "Text in Entry: Started"), selection: $store.usesCustomStart) {
                    Text(LocalizedStringResource("locNow", defaultValue: "Now", comment: "Message in Entry: Now")).tag(false)
                    Text(LocalizedStringResource("locChooseStartTime", defaultValue: "Choose start time", comment: "Text in Entry: Choose start time")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if store.usesCustomStart {
                    DatePicker(LocalizedStringResource("locStarted", defaultValue: "Started", comment: "Picker title in Entry: Started"), selection: $store.startedAt)
                }
            }
            Section(LocalizedStringResource("locStatus", defaultValue: "Status", comment: "Text in Entry: Status")) {
                Picker(LocalizedStringResource("locStatus", defaultValue: "Status", comment: "Text in Entry: Status"), selection: $store.hasEnd) {
                    Text(LocalizedStringResource("locStillSleeping", defaultValue: "Still sleeping", comment: "Message in Entry: Still sleeping")).tag(false)
                    Text(LocalizedStringResource("locAlreadyWokeUp", defaultValue: "Already woke up", comment: "Text in Entry: Already woke up")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if store.hasEnd {
                    DatePicker(LocalizedStringResource("locEnded", defaultValue: "Ended", comment: "Picker title in Entry: Ended"), selection: $store.endedAt, in: (store.usesCustomStart ? store.startedAt : .distantPast)...Date.now)
                }
            }
            if let error = store.validationError ?? store.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
