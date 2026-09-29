import ComposableArchitecture2
import SwiftUI
import UnetonCore

struct FamilyManagementContent: View {
    @Environment(SessionStore.self) private var session
    @Bindable var store: StoreOf<FamilyManagement>
    private var isOwner: Bool { store.snapshot?.myRole == "owner" }

    var body: some View {
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
    }

    private var babiesSection: some View {
        Section("Babies") {
            if store.children.isEmpty && !store.isLoadingChildren {
                Text("No babies yet").foregroundStyle(.secondary)
            }
            ForEach(store.children) { child in
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
