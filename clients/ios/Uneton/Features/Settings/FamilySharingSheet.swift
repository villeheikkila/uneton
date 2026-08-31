import CoreImage.CIFilterBuiltins
import SwiftUI

struct FamilySharingSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    let familyID: UUID
    @State private var inviteURL: URL?
    @State private var isConfirmingAccountDeletion = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "person.2.badge.plus")
                    .font(.system(size: 48))
                    .foregroundStyle(.indigo)
                Text("Invite a caregiver")
                    .font(.title2.bold())
                Text("They can log and end sleep, and changes appear on both phones. The link expires in seven days and works once.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if let inviteURL {
                    QRCodeImage(value: inviteURL.absoluteString)
                        .frame(width: 180, height: 180)
                        .accessibilityLabel("Family invitation QR code")
                    ShareLink(item: inviteURL, subject: Text("Join our Uneton family")) {
                        Label("Share invitation", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    ProgressView("Creating secure invitation…")
                }
                Spacer()

                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    Text("This device").font(.headline)
                    Toggle("Push notifications", isOn: Binding(
                        get: { session.notificationsEnabled },
                        set: { value in Task { await session.setNotificationsEnabled(value) } }
                    ))
                    Toggle("Live Activities", isOn: Binding(
                        get: { session.liveActivitiesEnabled },
                        set: { value in Task { await session.setLiveActivitiesEnabled(value) } }
                    ))
                    Picker("Sleep reminder", selection: Binding(
                        get: { session.reminderLeadMinutes },
                        set: { value in Task { await session.setReminderLeadMinutes(value) } }
                    )) {
                        Text("At predicted time").tag(0)
                        Text("15 minutes before").tag(15)
                        Text("30 minutes before").tag(30)
                        Text("1 hour before").tag(60)
                    }
                }

                Divider()

                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await signOutButtonTapped() }
                }
                .buttonStyle(.bordered)
                .disabled(session.isWorking)

                Button("Delete account", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
                    isConfirmingAccountDeletion = true
                }
                .disabled(session.isWorking)

                if let error = session.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .navigationTitle("Family")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task { inviteURL = await session.createInvite(familyID: familyID) }
            .confirmationDialog(
                "Delete your Uneton account?",
                isPresented: $isConfirmingAccountDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete account and family data", role: .destructive) {
                    Task { await deleteAccountButtonTapped() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This revokes Sign in with Apple, signs out every device, and permanently deletes families you own.")
            }
        }
        .presentationDetents([.large])
    }

    private func signOutButtonTapped() async {
        if await session.signOut() { dismiss() }
    }

    private func deleteAccountButtonTapped() async {
        if await session.deleteAccount() { dismiss() }
    }
}

private struct QRCodeImage: View {
    let value: String
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        if let image = image {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    private var image: UIImage? {
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = context.createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
