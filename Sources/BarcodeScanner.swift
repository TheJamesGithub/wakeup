import AVFoundation
import SwiftUI
import UIKit

/// Camera view that reports every barcode it reads.
struct BarcodeScannerView: UIViewControllerRepresentable {
    var torchOn: Bool
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {
        vc.onCode = onCode
        vc.setTorch(torchOn)
    }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "wakeup.scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var device: AVCaptureDevice?
    private var configured = false
    private var wantTorch = false
    private var lastCode: String?
    private var lastCodeTime = Date.distantPast
    private let messageLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        messageLabel.textColor = .white
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
        ])

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.configure() } else { self.showDenied() }
                }
            }
        default:
            showDenied()
        }
    }

    private func showDenied() {
        messageLabel.text = "Camera is off for WakeUp.\nTurn it on in Settings > Apps > WakeUp."
    }

    private func configure() {
        guard !configured,
              let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            messageLabel.text = "Camera not available."
            return
        }
        configured = true
        self.device = device

        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            let wanted: [AVMetadataObject.ObjectType] = [
                .ean13, .ean8, .upce, .code128, .code39, .code39Mod43, .code93,
                .itf14, .interleaved2of5, .qr, .dataMatrix, .pdf417, .aztec,
            ]
            output.metadataObjectTypes = wanted.filter { output.availableMetadataObjectTypes.contains($0) }
        }
        session.commitConfiguration()

        do {
            try device.lockForConfiguration()
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        } catch {}

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        startRunning()
    }

    private func startRunning() {
        let session = self.session
        sessionQueue.async {
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async { self.applyTorch() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if configured { startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        wantTorch = false
        applyTorch()
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    func setTorch(_ on: Bool) {
        wantTorch = on
        applyTorch()
    }

    private func applyTorch() {
        guard let d = device, d.hasTorch, session.isRunning else { return }
        let mode: AVCaptureDevice.TorchMode = wantTorch ? .on : .off
        guard d.torchMode != mode else { return }
        do {
            try d.lockForConfiguration()
            d.torchMode = mode
            d.unlockForConfiguration()
        } catch {}
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let raw = obj.stringValue else { return }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        if code == lastCode && Date().timeIntervalSince(lastCodeTime) < 1.5 { return }
        lastCode = code
        lastCodeTime = Date()
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        onCode?(code)
    }
}
