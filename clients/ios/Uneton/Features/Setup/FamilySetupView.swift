import AVFoundation
import ComposableArchitecture2
import SQLiteData
import SwiftUI
import UnetonCore

struct FamilySetupView: View {
    @Bindable var store: StoreOf<FamilySetup>
    @FetchAll(PendingCommand.order { $0.createdAt.desc() }) private var pendingCommands

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "figure.child")
                            .font(.system(size: 38, weight: .medium))
                            .foregroundStyle(.indigo)
                            .padding(.bottom, 4)
                        Text("Add your baby")
                            .font(.largeTitle.bold())
                        Text("Keep sleep, growth and temperature in one shared place. Have an invitation? Scan it below.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !pendingCommands.isEmpty {
                        Label("Unsent changes are saved on this device. Scan a new invitation from that family to restore access and sync them.",
                              systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Baby’s name")
                                .font(.subheadline.weight(.semibold))
                            TextField("Name or nickname", text: $store.childName)
                                .textContentType(.nickname)
                                .textFieldStyle(.roundedBorder)
                                .submitLabel(.done)
                        }

                        DatePicker("Date of birth", selection: $store.birthDate, in: ...Date.now, displayedComponents: .date)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Growth reference")
                                .font(.subheadline.weight(.semibold))
                            Picker("Growth reference", selection: $store.growthReference) {
                                Text("None").tag("none")
                                Text("Girl").tag("girl")
                                Text("Boy").tag("boy")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            Text("Optional Finnish growth chart. You can change this later.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if store.request.isRunning { ProgressView() }
                    if let error = store.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaBar(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        store.send(.scanInvitationButtonTapped)
                    } label: {
                        Label("Scan invite", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.glass)

                    Button {
                        store.send(.addBabyButtonTapped)
                    } label: {
                        Label("Add baby", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.indigo)
                    .disabled(
                        store.childName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || store.request.isRunning
                    )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .sheet(isPresented: $store.isScanning) {
                QRCodeScanner { value in
                    store.send(.invitationCodeScanned(value))
                }
                .overlay(alignment: .bottom) {
                    Text("Point the camera at your family invitation code")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(16)
                        .background(.black.opacity(0.75), in: .rect(cornerRadius: 16))
                        .padding(24)
                }
                .background(.black)
            }
        }
    }
}

#if DEBUG
#Preview("Family setup") { ScreenFixtures.preview(.familySetup) }
#Preview("Invitation scanner") { ScreenFixtures.preview(.invitationScannerSheet) }
#endif

struct QRCodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        session.startRunning()
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        Task { @MainActor [weak self, value] in
            self?.handleScannedCode(value)
        }
    }

    private func handleScannedCode(_ value: String) {
        session.stopRunning()
        onCode?(value)
    }
}
