import ComposableArchitecture2
import SwiftUI

struct SleepEntryContent: View {
    @Bindable var store: StoreOf<SleepEntry>

    var body: some View {
        Form {
            Section {
                Toggle(LocalizedStringResource("locChooseStartTime", defaultValue: "Choose start time", comment: "Text in Entry: Choose start time"), isOn: $store.usesCustomStart)
                if store.usesCustomStart {
                    DatePicker(LocalizedStringResource("locStarted", defaultValue: "Started", comment: "Picker title in Entry: Started"), selection: $store.startedAt)
                } else {
                    LabeledContent(LocalizedStringResource("locStarted", defaultValue: "Started", comment: "Text in Entry: Started"), value: String(localized: LocalizedStringResource("locNow", defaultValue: "Now", comment: "Message in Entry: Now")))
                }
                Toggle(LocalizedStringResource("locAlreadyWokeUp", defaultValue: "Already woke up", comment: "Text in Entry: Already woke up"), isOn: $store.hasEnd)
                if store.hasEnd {
                    DatePicker(LocalizedStringResource("locEnded", defaultValue: "Ended", comment: "Picker title in Entry: Ended"), selection: $store.endedAt, in: (store.usesCustomStart ? store.startedAt : .distantPast)...Date.now)
                } else {
                    LabeledContent(LocalizedStringResource("locStatus", defaultValue: "Status", comment: "Text in Entry: Status"), value: String(localized: LocalizedStringResource("locStillSleeping", defaultValue: "Still sleeping", comment: "Message in Entry: Still sleeping")))
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
