import CoreImage.CIFilterBuiltins
import ComposableArchitecture2
import SwiftUI

struct FamilySharingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: StoreOf<FamilySharing>

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
                if let inviteURL = store.inviteURL {
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
                        get: { store.notificationsEnabled },
                        set: { store.send(.notificationsChanged($0)) }
                    ))
                    Toggle("Live Activities", isOn: Binding(
                        get: { store.liveActivitiesEnabled },
                        set: { store.send(.liveActivitiesChanged($0)) }
                    ))
                    Picker("Sleep reminder", selection: Binding(
                        get: { store.reminderLeadMinutes },
                        set: { store.send(.reminderLeadChanged($0)) }
                    )) {
                        Text("At predicted time").tag(0)
                        Text("15 minutes before").tag(15)
                        Text("30 minutes before").tag(30)
                        Text("1 hour before").tag(60)
                    }
                }

                Divider()

                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                    store.send(.signOutButtonTapped)
                }
                .buttonStyle(.bordered)
                .disabled(store.accountRequest.isRunning)

                Button("Delete account", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
                    store.send(.deleteAccountPromptButtonTapped)
                }
                .disabled(store.accountRequest.isRunning)

                HStack(spacing: 20) {
                    Link("Privacy Policy", destination: LegalLinks.privacy)
                    Link("Terms of Service", destination: LegalLinks.terms)
                }
                .font(.footnote)

                if let error = store.errorMessage {
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
            .confirmationDialog(
                "Delete your Uneton account?",
                isPresented: $store.isConfirmingAccountDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) {
                    store.send(.deleteAccountButtonTapped)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This signs out every device. Families you own transfer to another caregiver when one is present; otherwise their diaries are deleted.")
            }
        }
        .presentationDetents([.large])
        .onChange(of: store.isFinished) { _, finished in
            if finished { dismiss() }
        }
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
