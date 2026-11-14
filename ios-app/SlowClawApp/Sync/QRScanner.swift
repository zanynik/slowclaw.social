import SwiftUI
import AVFoundation

/// What a browser shows as a QR code when it wants to sign in.
enum BrowserCode: Equatable {
    /// slowclaw.social: the phone hands the browser a session sealed with `key`.
    case cloud(id: String, key: String, expires: Double)
    /// The no-cloud view served by this iPhone: approve pairing `id`.
    case local(id: String)

    static func parse(_ raw: String) -> BrowserCode? {
        guard raw.count < 2000, let data = raw.data(using: .utf8),
              let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = v["type"] as? String, let id = v["id"] as? String,
              id.count <= 64, Hex.bytes(id) != nil else { return nil }
        switch type {
        case "slowclaw-cloud":
            guard id.count == 64, let key = v["key"] as? String, key.count == 64, Hex.bytes(key) != nil,
                  let expires = (v["expires"] as? NSNumber)?.doubleValue else { return nil }
            return .cloud(id: id.lowercased(), key: key.lowercased(), expires: expires)
        case "slowclaw-local":
            guard id.count >= 32 else { return nil }
            return .local(id: id.lowercased())
        default:
            return nil
        }
    }
}

/// Camera QR scanner. Calls `onCode` once with the first code it reads.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var delivered = false
        private let message = UILabel()

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            message.textColor = .white
            message.numberOfLines = 0
            message.textAlignment = .center
            message.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(message)
            NSLayoutConstraint.activate([
                message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            ])
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.configure() } else {
                        self.message.text = "Allow camera access in Settings to scan the code."
                    }
                }
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                message.text = "The camera is not available."
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            preview = layer
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !delivered,
                  let code = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first
            else { return }
            delivered = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode?(code)
        }
    }
}

/// Sheet that scans a browser's code and signs that browser in.
struct BrowserSignInSheet: View {
    @EnvironmentObject private var cloud: CloudSync
    @EnvironmentObject private var local: LocalServer
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var working = false
    @State private var done = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if working || done || status != nil {
                    VStack(spacing: 16) {
                        Spacer()
                        if working { ProgressView() }
                        if done { Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green) }
                        Text(status ?? "").multilineTextAlignment(.center).padding(.horizontal)
                        if !working {
                            Button(done ? "Done" : "Scan again") {
                                if done { dismiss() } else { status = nil }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                    }
                } else {
                    QRScannerView { raw in Task { await handle(raw) } }
                        .ignoresSafeArea(edges: .bottom)
                    Text("Open slowclaw.social, or this iPhone's local address, on your computer and scan the code it shows.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .navigationTitle("Sign in a browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func handle(_ raw: String) async {
        guard let code = BrowserCode.parse(raw) else {
            status = "That is not a SlowClaw sign-in code."
            return
        }
        working = true
        defer { working = false }
        do {
            switch code {
            case let .cloud(id, key, expires):
                guard expires > Date().timeIntervalSince1970 else {
                    status = "That code has expired. Refresh the page for a new one."
                    return
                }
                try await cloud.approveBrowser(id: id, key: key)
                status = "The browser is signed in to your account."
            case let .local(id):
                try local.approve(pairing: id)
                status = "The browser can now view this iPhone's journals over your Wi-Fi."
            }
            done = true
        } catch {
            status = error.localizedDescription
        }
    }
}
