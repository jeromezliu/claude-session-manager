import SwiftUI
import AVFoundation

struct WelcomeView: View {
    @State private var pairing = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Claude Sessions").font(.largeTitle.weight(.semibold))
            Text("Read and drive the Claude Code sessions on your Mac — answer approvals, keep work moving while you're away from the desk.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("On the Mac: ⋯ → Remote Access… → turn it on", systemImage: "1.circle")
                Label("Click “Show Pairing Code”", systemImage: "2.circle")
                Label("Scan it here", systemImage: "3.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Button {
                pairing = true
            } label: {
                Text("Pair with a Mac").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $pairing) { PairingView(initialLink: nil) }
    }
}

/// Scan or paste the Mac's pairing link, then wait for approval on the Mac.
struct PairingView: View {
    let initialLink: PairingLink?

    @EnvironmentObject private var hosts: HostStore
    @EnvironmentObject private var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @State private var link: PairingLink?
    @State private var pasted = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let link {
                    waiting(link)
                } else {
                    chooser
                }
            }
            .navigationTitle("Pair with a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .onAppear { if let initialLink { start(initialLink) } }
    }

    private var chooser: some View {
        VStack(spacing: 16) {
            if QRScanner.isAvailable {
                QRScanner { code in
                    if let l = PairingLink(code) { start(l) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .frame(maxHeight: 360)
                Text("Point the camera at the code on your Mac.").foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("No camera", systemImage: "camera",
                                       description: Text("Copy the pairing link on the Mac and paste it below."))
            }
            HStack {
                TextField("Or paste the pairing link", text: $pasted)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Pair") {
                    if let l = PairingLink(pasted) { start(l) } else { error = "That isn't a pairing link." }
                }
                .disabled(pasted.isEmpty)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            Spacer()
        }
        .padding()
    }

    private func waiting(_ link: PairingLink) -> some View {
        VStack(spacing: 18) {
            Spacer()
            if working {
                ProgressView().controlSize(.large)
                Text("Approve this device on your Mac").font(.title3.weight(.semibold))
            } else if let error {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(error).multilineTextAlignment(.center)
                Button("Try Again") { self.link = nil; self.error = nil }
            }
            VStack(spacing: 4) {
                Text("Check the Mac shows the same code:").foregroundStyle(.secondary)
                Text(PairingSecurity.code(forFingerprint: link.fingerprint))
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
            }
            .padding(.top, 8)
            Spacer()
        }
        .padding()
    }

    private func start(_ l: PairingLink) {
        link = l
        working = true
        error = nil
        Task {
            do {
                let (host, token) = try await Pairing.pair(l, deviceName: UIDevice.current.name)
                hosts.add(host, token: token)
                client.connect(to: host, token: token)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// Camera QR reader (AVFoundation). Unavailable on the simulator.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    static var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var delivered = false

        override func viewDidLoad() {
            super.viewDidLoad()
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.first?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                  code.hasPrefix("csm://") else { return }
            delivered = true
            onCode?(code)
        }
    }
}
