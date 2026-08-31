import AVFoundation
import SwiftUI

struct FamilySetupView: View {
    @Environment(SessionStore.self) private var session
    @State private var childName = ""
    @State private var birthDate = Calendar.current.date(byAdding: .month, value: -6, to: .now) ?? .now
    @State private var growthReference: String?
    @State private var isScanning = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "person.2.badge.plus")
                    .font(.system(size: 52))
                    .foregroundStyle(.indigo)
                Text("Set up your family")
                    .font(.title.bold())
                Text("Create your child’s sleep diary, or scan a caregiver’s QR invitation to join theirs.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 16) {
                    Text("Your baby")
                        .font(.headline)
                    TextField("Baby’s name", text: $childName)
                        .textFieldStyle(.roundedBorder)
                    DatePicker("Birthday", selection: $birthDate, in: ...Date.now, displayedComponents: .date)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Gender")
                            .font(.subheadline.weight(.medium))
                        Picker("Gender", selection: $growthReference) {
                            Text("Girl").tag(Optional("girl"))
                            Text("Boy").tag(Optional("boy"))
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        Text("This selects the Finnish growth reference curves. You can change or turn them off later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Create sleep diary") {
                        guard let growthReference else { return }
                        Task {
                            await session.createChildFamily(
                                childName: childName,
                                birthDate: birthDate,
                                growthReference: growthReference
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        childName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || growthReference == nil
                            || session.isWorking
                    )
                }
                .padding(20)
                .background(.background.secondary, in: .rect(cornerRadius: 24))

                Divider()
                Button("Scan family invitation", systemImage: "qrcode.viewfinder") { isScanning = true }
                    .buttonStyle(.bordered)
                if session.isWorking { ProgressView() }
                if let error = session.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
                Spacer()
            }
            .padding(24)
            .sheet(isPresented: $isScanning) {
                QRCodeScanner { value in
                    isScanning = false
                    guard let url = URL(string: value) else { return }
                    Task { await session.handle(url: url) }
                }
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
