import ComposableArchitecture2
import SwiftUI

struct SleepEntryContent: View {
    @Bindable var store: StoreOf<SleepEntry>

    var body: some View {
        Form {
            Section {
                Toggle("Choose start time", isOn: $store.usesCustomStart)
                if store.usesCustomStart {
                    DatePicker("Started", selection: $store.startedAt)
                } else {
                    LabeledContent("Started", value: "Now")
                }
                Toggle("Already woke up", isOn: $store.hasEnd)
                if store.hasEnd {
                    DatePicker("Ended", selection: $store.endedAt, in: (store.usesCustomStart ? store.startedAt : .distantPast)...Date.now)
                } else {
                    LabeledContent("Status", value: "Still sleeping")
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
