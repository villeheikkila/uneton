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
                Section(LocalizedStringResource("locFamily", defaultValue: "Family", comment: "Text in FamilyManagement: Family")) {
                    TextField(LocalizedStringResource("locFamilyName", defaultValue: "Family name", comment: "Text field placeholder in FamilyManagement: Family name"), text: $store.familyName)
                        .disabled(!isOwner)
                    if isOwner {
                        Button(LocalizedStringResource("locSaveFamilyName", defaultValue: "Save family name", comment: "Button title in FamilyManagement: Save family name")) { store.send(.saveFamilyName) }
                            .disabled(store.request.isRunning || store.familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Button(LocalizedStringResource("locCreateAnotherFamily", defaultValue: "Create another family", comment: "Button title in FamilyManagement: Create another family"), systemImage: "plus") { store.send(.createFamily) }
                }
                Section(LocalizedStringResource("locYourProfile", defaultValue: "Your profile", comment: "Text in FamilyManagement: Your profile")) {
                    TextField(LocalizedStringResource("locYourName", defaultValue: "Your name", comment: "Text field placeholder in FamilyManagement: Your name"), text: $store.profileName)
                        .textContentType(.name)
                    Button(LocalizedStringResource("locSaveName", defaultValue: "Save name", comment: "Button title in FamilyManagement: Save name")) { store.send(.saveProfile) }
                        .disabled(store.request.isRunning || store.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                babiesSection
                Section(LocalizedStringResource("locCaregivers", defaultValue: "Caregivers", comment: "Text in FamilyManagement: Caregivers")) {
                    ForEach(snapshot.members) { member in
                        caregiverRow(member, myUserID: snapshot.myUserID)
                    }
                    if isOwner { Button(LocalizedStringResource("locInviteCaregiver", defaultValue: "Invite caregiver", comment: "Button title in FamilyManagement: Invite caregiver"), systemImage: "person.badge.plus") { store.send(.invite) } }
                    if let url = store.inviteURL {
                        QRCodeImage(value: url.absoluteString)
                            .frame(width: 160, height: 160)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(LocalizedStringResource("locFamilyInvitationQRCode", defaultValue: "Family invitation QR code", comment: "Label in FamilyManagement: Family invitation QR code"))
                        ShareLink(item: url) { Label(LocalizedStringResource("locShareNewInvitation", defaultValue: "Share new invitation", comment: "Label in FamilyManagement: Share new invitation"), systemImage: "square.and.arrow.up") }
                    }
                }
                if isOwner && !snapshot.pendingInvites.isEmpty {
                    Section(LocalizedStringResource("locPendingInvitations", defaultValue: "Pending invitations", comment: "Text in FamilyManagement: Pending invitations")) {
                        ForEach(snapshot.pendingInvites) { invite in
                            HStack {
                                Text(.locInviteExpires(invite.expiresAt.formatted(date: .abbreviated, time: .omitted)))
                                Spacer()
                                Button(LocalizedStringResource("locRevoke", defaultValue: "Revoke", comment: "Button title in FamilyManagement: Revoke"), role: .destructive) { store.send(.prompt(.revoke(invite.id))) }
                            }
                        }
                    }
                }
                Section {
                    Button(LocalizedStringResource("locScanFamilyInvitation", defaultValue: "Scan family invitation", comment: "Button title in FamilyManagement: Scan family invitation"), systemImage: "qrcode.viewfinder") {
                        store.send(.scanInvitation)
                    }
                    Button(LocalizedStringResource("locDeviceAndAccountSettings", defaultValue: "Device and account settings", comment: "Button title in FamilyManagement: Device and account settings"), systemImage: "gearshape") {
                        store.send(.showDeviceSettings(session.notificationsEnabled,
                            session.liveActivitiesEnabled, session.reminderLeadMinutes))
                    }
                    if isOwner {
                        Button(LocalizedStringResource("locDeleteFamily", defaultValue: "Delete family", comment: "Button title in FamilyManagement: Delete family"), role: .destructive) { store.send(.prompt(.deleteFamily)) }
                    } else {
                        Button(LocalizedStringResource("locLeaveFamily", defaultValue: "Leave family", comment: "Button title in FamilyManagement: Leave family"), role: .destructive) { store.send(.prompt(.leave)) }
                    }
                }
            } else {
                babiesSection
                Section {
                    if store.load.isRunning {
                        ProgressView(LocalizedStringResource("locLoadingFamily", defaultValue: "Loading family…", comment: "Text in FamilyManagement: Loading family…"))
                    } else {
                        Button(LocalizedStringResource("locRetryFamilyDetails", defaultValue: "Retry family details", comment: "Button title in FamilyManagement: Retry family details")) { store.send(.refresh) }
                    }
                    Button(LocalizedStringResource("locScanFamilyInvitation", defaultValue: "Scan family invitation", comment: "Button title in FamilyManagement: Scan family invitation"), systemImage: "qrcode.viewfinder") {
                        store.send(.scanInvitation)
                    }
                    Button(LocalizedStringResource("locDeviceAndAccountSettings", defaultValue: "Device and account settings", comment: "Button title in FamilyManagement: Device and account settings"), systemImage: "gearshape") {
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
        Section(LocalizedStringResource("locBabies", defaultValue: "Babies", comment: "Text in FamilyManagement: Babies")) {
            if store.children.isEmpty && !store.isLoadingChildren {
                Text("locNoBabiesYet", comment: "Text in FamilyManagement: No babies yet").foregroundStyle(.secondary)
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
            Button(LocalizedStringResource("locAddBaby", defaultValue: "Add baby", comment: "Button title in FamilyManagement: Add baby"), systemImage: "plus") { store.send(.addChild) }
        }
    }

    private func caregiverRow(_ member: ManagedFamilyMember, myUserID: UserID) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(member.displayName)
                Text(member.role == "owner" ? LocalizedStringResource("locOwner", defaultValue: "Owner", comment: "Family role with management permissions") : LocalizedStringResource("locCaregiver", defaultValue: "Caregiver", comment: "Family member who cares for the baby, or default caregiver display name"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if member.id == myUserID { Text("locYou", comment: "Text in FamilyManagement: You").foregroundStyle(.secondary) }
        }
        .contextMenu {
            if isOwner && member.id != myUserID {
                Button(LocalizedStringResource("locTransferOwnership", defaultValue: "Transfer ownership", comment: "Button title in FamilyManagement: Transfer ownership")) { store.send(.prompt(.transfer(member.id))) }
                Button(LocalizedStringResource("locRemoveCaregiver", defaultValue: "Remove caregiver", comment: "Button title in FamilyManagement: Remove caregiver"), role: .destructive) { store.send(.prompt(.remove(member.id))) }
            }
        }
    }
}
