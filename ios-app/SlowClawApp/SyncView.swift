// SyncView.swift — the QR-paired LAN sync screen (iOS = client).
//
// The user points the camera at the Windows companion's QR; this screen scans
// it, then drives the sync exchange via SyncClient. No new dependency — QR
// scanning uses AVFoundation's AVCaptureMetadataOutput (pure first-party).
//
// This screen is reached from the settings surface (see SlowClawApp.swift's
// "Sync with Desktop" button). It needs NSCameraUsageDescription +
// NSLocalNetworkUsageDescription in Info.plist (added in this change).

import SwiftUI
import AVFoundation

struct SyncView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var scanned = false
    @State private var phase: String = "Point the camera at the SlowClaw Sync QR on your computer."
    @State private var progress: SyncProgress?
    @State private var errorMessage: String?
    @State private var syncing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if !syncing {
                    QRScanner { payload in
                        guard !scanned else { return }
                        scanned = true
                        Task { await runSync(payload: payload) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 280)
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                Text(phase)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if let p = progress {
                    ProgressView(value: Double(p.pulled + p.pushed), total: Double(max(p.total, 1)))
                        .padding(.horizontal)
                    Text("\(p.pulled + p.pushed) / \(p.total)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Run the full sync exchange against the scanned server.
    private func runSync(payload: SyncPairingPayload) async {
        syncing = true
        phase = "Connecting to \(payload.name)…"
        let client = SyncClient(payload: payload, memory: state.memory)
        do {
            try await client.run { p in
                Task { @MainActor in
                    self.progress = p
                    self.phase = p.phase
                }
            }
        } catch {
            Task { @MainActor in
                self.errorMessage = error.localizedDescription
                self.phase = "Sync failed."
            }
        }
        syncing = false
    }
}

// MARK: - QR scanner (AVFoundation, no third-party dep)

/// A SwiftUI wrapper around a UIViewController that runs an AVCaptureSession
/// for QR detection. Calls `onScan` exactly once per detected payload.
private struct QRScanner: UIViewControllerRepresentable {
    let onScan: (SyncPairingPayload) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        ScannerVC(onScan: onScan)
    }
    func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}
}

private final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let onScan: (SyncPairingPayload) -> Void
    private let session = AVCaptureSession()
    private var delivered = false

    init(onScan: @escaping (SyncPairingPayload) -> Void) {
        self.onScan = onScan
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            // No camera (simulator). Nothing to render; SyncView's status text
            // still guides the user. Live scan requires a real device.
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.metadataObjectTypes = [.qr]
        output.setMetadataObjectsDelegate(self, queue: .main)

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (view.layer.sublayers?.first as? AVCaptureVideoPreviewLayer)?.frame = view.bounds
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !delivered,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let payload = obj.stringValue,
              let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SyncPairingPayload.self, from: data)
        else { return }
        delivered = true
        session.stopRunning()
        onScan(decoded)
    }
}
