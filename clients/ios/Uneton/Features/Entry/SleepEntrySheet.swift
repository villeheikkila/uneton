import UnetonCore
import SwiftUI

struct SleepEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    let family: Family
    let child: Child
    let sleep: SleepSession?

    @State private var usesCustomStart = false
    @State private var hasEnd = false
    @State private var startedAt = Date.now
    @State private var endedAt = Date.now

    init(family: Family, child: Child, sleep: SleepSession? = nil) {
        self.family = family
        self.child = child
        self.sleep = sleep
        _usesCustomStart = State(initialValue: sleep != nil)
        _hasEnd = State(initialValue: sleep?.endedAt != nil)
        _startedAt = State(initialValue: sleep?.startedAt ?? .now)
        _endedAt = State(initialValue: sleep?.endedAt ?? .now)
    }

    var body: some View {
        @Bindable var session = session
        NavigationStack {
            Form {
                Section {
                    Toggle("Choose start time", isOn: $usesCustomStart)
                    if usesCustomStart {
                        DatePicker("Started", selection: $startedAt)
                    } else {
                        LabeledContent("Started", value: "Now")
                    }
                    Toggle("Already woke up", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("Ended", selection: $endedAt, in: (usesCustomStart ? startedAt : .distantPast)...Date.now)
                    } else {
                        LabeledContent("Status", value: "Still sleeping")
                    }
                }
                if let error = validationError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(sleep == nil ? (hasEnd ? "Log sleep" : "Start sleep") : "Edit sleep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sleep == nil ? (hasEnd ? "Add" : "Start") : "Save") {
                        Task { await saveButtonTapped() }
                    }
                    .disabled(validationError != nil || session.isWorking)
                }
            }
        }
    }

    private var validationError: String? {
        if hasEnd && endedAt <= effectiveStart { return "End time must be after start time." }
        if effectiveStart > .now { return "Start time can’t be in the future." }
        return nil
    }

    private var effectiveStart: Date { usesCustomStart ? startedAt : .now }

    private func saveButtonTapped() async {
        if sleep != nil || hasEnd {
            await session.logSleep(
                familyID: family.id,
                childID: child.id,
                sessionID: sleep?.id,
                startedAt: effectiveStart,
                endedAt: hasEnd ? endedAt : nil
            )
        } else {
            await session.startSleep(familyID: family.id, childID: child.id, childName: child.nickname, startedAt: effectiveStart)
        }
        if session.errorMessage == nil { dismiss() }
    }
}
