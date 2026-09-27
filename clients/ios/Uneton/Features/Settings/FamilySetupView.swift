import AVFoundation
import ComposableArchitecture2
import SwiftUI

struct FamilySetupView: View {
    @Bindable var store: StoreOf<FamilySetup>

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "person.2.badge.plus")
                        .font(.system(size: 52))
                        .foregroundStyle(.indigo)
                    Text("Set up your family")
                        .font(.title.bold())
                    Text("Create your child’s sleep diary, or scan a caregiver’s QR invitation to join theirs.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Your baby")
                            .font(.headline)
                        TextField("Baby’s name", text: $store.childName)
                            .textFieldStyle(.roundedBorder)
                        DatePicker("Birthday", selection: $store.birthDate, in: ...Date.now, displayedComponents: .date)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Gender")
                                .font(.subheadline.weight(.medium))
                            Picker("Gender", selection: $store.growthReference) {
                                Text("Girl").tag(Optional("girl"))
                                Text("Boy").tag(Optional("boy"))
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            Text("This selects the Finnish growth reference curves. You can change or turn them off later.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button("Create sleep diary") {
                            store.send(.createSleepDiaryButtonTapped)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            store.childName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || store.growthReference == nil
                                || store.request.isRunning
                        )
                    }
                    .padding(20)
                    .background(.background.secondary, in: .rect(cornerRadius: 24))

                    Divider()
                    Button("Scan family invitation", systemImage: "qrcode.viewfinder") {
                        store.send(.scanInvitationButtonTapped)
                    }
                    .buttonStyle(.bordered)
                    if store.request.isRunning { ProgressView() }
                    if let error = store.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                .padding(24)
            }
            .sheet(isPresented: $store.isScanning) {
                QRCodeScanner { value in
                    store.send(.invitationCodeScanned(value))
                }
                .overlay(alignment: .bottom) {
                    Text("Point the camera at a caregiver’s invitation QR code")
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

private struct QRCodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
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
