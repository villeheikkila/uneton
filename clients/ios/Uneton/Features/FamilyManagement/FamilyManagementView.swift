import ComposableArchitecture2
import Tagged
import SwiftUI
import UnetonCore

struct FamilyManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SessionStore.self) private var session
    @Bindable var store: StoreOf<FamilyManagement>
    let children: [Child]
    private var isOwner: Bool { store.snapshot?.myRole == "owner" }

    var body: some View {
        NavigationStack {
            Form {
                if let snapshot = store.snapshot {
                    Section("Family") {
                        TextField("Family name", text: $store.familyName)
                            .disabled(!isOwner)
                        if isOwner {
                            Button("Save family name") { store.send(.saveFamilyName) }
                                .disabled(store.request.isRunning || store.familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Button("Create another family", systemImage: "plus") { store.send(.createFamily) }
                    }
                    Section("Your profile") {
                        TextField("Your name", text: $store.profileName)
                            .textContentType(.name)
                        Button("Save name") { store.send(.saveProfile) }
                            .disabled(store.request.isRunning || store.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    babiesSection
                    Section("Caregivers") {
                        ForEach(snapshot.members) { member in
                            caregiverRow(member, myUserID: snapshot.myUserID)
                        }
                        if isOwner { Button("Invite caregiver", systemImage: "person.badge.plus") { store.send(.invite) } }
                        if let url = store.inviteURL {
                            QRCodeImage(value: url.absoluteString)
                                .frame(width: 160, height: 160)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("Family invitation QR code")
                            ShareLink(item: url) { Label("Share new invitation", systemImage: "square.and.arrow.up") }
                        }
                    }
                    if isOwner && !snapshot.pendingInvites.isEmpty {
                        Section("Pending invitations") {
                            ForEach(snapshot.pendingInvites) { invite in
                                HStack {
                                    Text("Expires \(invite.expiresAt, style: .date)")
                                    Spacer()
                                    Button("Revoke", role: .destructive) { store.send(.prompt(.revoke(invite.id))) }
                                }
                            }
                        }
                    }
                    Section {
                        Button("Scan family invitation", systemImage: "qrcode.viewfinder") {
                            store.send(.scanInvitation)
                        }
                        Button("Device and account settings", systemImage: "gearshape") {
                            store.send(.showDeviceSettings(session.notificationsEnabled,
                                session.liveActivitiesEnabled, session.reminderLeadMinutes))
                        }
                        if isOwner {
                            Button("Delete family", role: .destructive) { store.send(.prompt(.deleteFamily)) }
                        } else {
                            Button("Leave family", role: .destructive) { store.send(.prompt(.leave)) }
                        }
                    }
                } else {
                    babiesSection
                    Section {
                        if store.load.isRunning {
                            ProgressView("Loading family…")
                        } else {
                            Button("Retry family details") { store.send(.refresh) }
                        }
                        Button("Scan family invitation", systemImage: "qrcode.viewfinder") {
                            store.send(.scanInvitation)
                        }
                        Button("Device and account settings", systemImage: "gearshape") {
                            store.send(.showDeviceSettings(session.notificationsEnabled,
                                session.liveActivitiesEnabled, session.reminderLeadMinutes))
                        }
                    }
                }
                if let error = store.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .refreshable { await store.send(.refresh)?.value }
            .navigationTitle("Family")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $store.scope(\.childEditor)) { editor in
                ChildEditorView(store: editor)
            }
            .sheet(item: $store.scope(\.sharing)) { sharing in
                FamilySharingSheet(store: sharing)
            }
            .sheet(isPresented: $store.isAddingChild) {
                NavigationStack {
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
                    .navigationTitle("Add baby")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.send(.dismissAddChild) } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") { store.send(.saveNewChild) }
                                .disabled(store.request.isRunning || store.newChildName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            .sheet(isPresented: $store.isCreatingFamily) {
                NavigationStack {
                    Form {
                        TextField("Family name", text: $store.newFamilyName)
                        if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
                    }
                    .navigationTitle("New family")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.send(.dismissCreateFamily) } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Create") { store.send(.saveNewFamily) }
                                .disabled(store.request.isRunning || store.newFamilyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            .sheet(isPresented: $store.isScanning) {
                QRCodeScanner { value in store.send(.invitationCodeScanned(value)) }
                    .overlay(alignment: .bottom) {
                        Text("Point the camera at your family invitation code")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(16)
                            .background(.black.opacity(0.75), in: .rect(cornerRadius: 16))
                            .padding(24)
                    }
                    .background(.black)
            }
            .confirmationDialog("Confirm family change", isPresented: Binding(
                get: { store.confirmation != nil },
                set: { if !$0 { store.send(.dismissConfirmation) } }
            ), titleVisibility: .visible) {
                if let confirmation = store.confirmation {
                    Button(confirmation.title, role: confirmation.isDestructive ? .destructive : nil) {
                        store.send(.confirmationAccepted(confirmation))
                    }
                }
                Button("Cancel", role: .cancel) { store.send(.dismissConfirmation) }
            } message: {
                Text(store.confirmation?.detail ?? "")
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await store.send(.refresh)?.value }
        }
        .onChange(of: store.isFinished) { _, finished in if finished { dismiss() } }
    }

    private var babiesSection: some View {
        Section("Babies") {
            if children.isEmpty { Text("No babies yet").foregroundStyle(.secondary) }
            ForEach(children) { child in
                Button {
                    store.send(.editChild(child))
                } label: {
                    HStack {
                        Label(child.nickname, systemImage: "figure.child")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
            }
            Button("Add baby", systemImage: "plus") { store.send(.addChild) }
        }
    }

    private func caregiverRow(_ member: ManagedFamilyMember, myUserID: UserID) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(member.displayName)
                Text(member.role == "owner" ? "Owner" : "Caregiver")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if member.id == myUserID { Text("You").foregroundStyle(.secondary) }
        }
        .contextMenu {
            if isOwner && member.id != myUserID {
                Button("Transfer ownership") { store.send(.prompt(.transfer(member.id))) }
                Button("Remove caregiver", role: .destructive) { store.send(.prompt(.remove(member.id))) }
            }
        }
    }
}

private extension FamilyManagement.Confirmation {
    var title: String {
        switch self {
        case .remove: "Remove caregiver"
        case .transfer: "Transfer ownership"
        case .revoke: "Revoke invitation"
        case .leave: "Leave family"
        case .deleteFamily: "Delete family"
        }
    }
    var detail: String {
        switch self {
        case .remove: "This caregiver will lose access to the family."
        case .transfer: "The selected caregiver will become the owner. You will remain a caregiver."
        case .revoke: "The invitation will stop working."
        case .leave: "You will lose access to this family and its baby records."
        case .deleteFamily: "This permanently deletes the family and its baby records. Remove other caregivers first."
        }
    }
    var isDestructive: Bool {
        switch self {
        case .transfer: false
        default: true
        }
    }
}

struct ChildEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: StoreOf<ChildEditor>

    var body: some View {
        NavigationStack {
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
            .navigationTitle(store.child.nickname)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.save) }
                        .disabled(store.request.isRunning || store.validationMessage != nil)
                }
            }
            .confirmationDialog("Delete \(store.child.nickname)?", isPresented: $store.isConfirmingDeletion) {
                Button("Delete baby and records", role: .destructive) { store.send(.delete) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes this baby’s sleep, growth and temperature records for everyone in the family.") }
        }
        .onChange(of: store.isFinished) { _, finished in if finished { dismiss() } }
    }
}

#if DEBUG
#Preview("Family management") { ScreenFixtures.preview(.familyManagementSheet) }
#Preview("Baby settings") { ScreenFixtures.preview(.childEditorSheet) }
#endif
