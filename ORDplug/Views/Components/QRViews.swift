import SwiftUI
import CoreImage.CIFilterBuiltins
import AVFoundation

// MARK: - QR code rendering (replaces qrcode.js — native CoreImage)

struct QRCodeView: View {
    var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let img = Self.generate(text) {
            Image(uiImage: img)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        } else {
            Text("QR unavailable").foregroundStyle(.secondary)
        }
    }

    static func generate(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - QR scanning (send flow: scan a BSV address)

struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onCode = onCode
        return vc
    }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var handled = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            // check camera permission explicitly — a denied state must never
            // be a silent black screen
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                setupCamera()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    DispatchQueue.main.async {
                        if granted { self?.setupCamera() }
                        else { self?.showPermissionDenied() }
                    }
                }
            default:
                showPermissionDenied()
            }
        }

        private func setupCamera() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                showPermissionDenied()
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.frame = view.bounds
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }

        /// inline explanation + shortcut to Settings (no black screen, no alert)
        private func showPermissionDenied() {
            let label = UILabel()
            label.text = "Camera access is off for ORD/net.\nAllow it in Settings to scan QR codes."
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .white
            label.font = .preferredFont(forTextStyle: .callout)

            var config = UIButton.Configuration.filled()
            config.title = "Open Settings"
            config.cornerStyle = .capsule
            config.baseBackgroundColor = .white
            config.baseForegroundColor = .black
            let button = UIButton(configuration: config, primaryAction: UIAction { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            })

            let stack = UIStackView(arrangedSubviews: [label, button])
            stack.axis = .vertical
            stack.spacing = 16
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
            ])
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !handled,
                  let obj = objects.first as? AVMetadataMachineReadableCodeObject,
                  var code = obj.stringValue else { return }
            handled = true
            // tolerate bitcoin-style URIs: strip scheme + query
            if let colon = code.firstIndex(of: ":") , code.lowercased().hasPrefix("bitcoin") || code.lowercased().hasPrefix("bsv") {
                code = String(code[code.index(after: colon)...])
            }
            if let q = code.firstIndex(of: "?") { code = String(code[..<q]) }
            onCode?(code.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onCode: (String) -> Void

    var body: some View {
        NavigationStack {
            QRScannerView { code in
                onCode(code)
                dismiss()
            }
            .ignoresSafeArea()
            .navigationTitle("Scan address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
