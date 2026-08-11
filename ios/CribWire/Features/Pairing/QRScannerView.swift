import AVFoundation
import SwiftUI
import UIKit
import VisionKit

/// Camera preview that reports scanned QR payload strings.
///
/// Uses `DataScannerViewController` (VisionKit) where it is available — it is the
/// choice in `ios-app.md` §4 and gives guidance and highlighting for free. It
/// needs an A12 device, though, while CribWire supports iOS 16 back to the A11
/// iPhone 8, so there is a plain `AVCaptureMetadataOutput` fallback.
struct QRScannerView: View {
    /// Called for every decoded payload; the caller decides what is a pairing URL.
    let onScan: (String) -> Void

    var body: some View {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            DataScannerRepresentable(onScan: onScan)
        } else {
            MetadataScannerRepresentable(onScan: onScan)
        }
    }
}

// MARK: - VisionKit

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
        if !controller.isScanning {
            try? controller.startScanning()
        }
    }

    static func dismantleUIViewController(
        _ controller: DataScannerViewController,
        coordinator: Coordinator
    ) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScan: (String) -> Void

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    onScan(payload)
                }
            }
        }
    }
}

// MARK: - AVFoundation fallback

private struct MetadataScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> MetadataScannerViewController {
        let controller = MetadataScannerViewController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ controller: MetadataScannerViewController, context: Context) {
        controller.onScan = onScan
    }
}

/// Minimal QR scanner for devices VisionKit does not support.
final class MetadataScannerViewController: UIViewController {
    var onScan: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSession()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopSession()
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        // `AVCaptureMetadataOutput` requires a `DispatchQueue` — an Apple API
        // that forces GCD. The main queue keeps the callback on the actor the UI
        // already lives on; QR metadata arrives at a handful of frames a second.
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    private func startSession() {
        guard !session.isRunning else { return }
        // `startRunning` blocks; never on the main actor.
        let session = self.session
        Task.detached(priority: .userInitiated) {
            session.startRunning()
        }
    }

    private func stopSession() {
        guard session.isRunning else { return }
        let session = self.session
        Task.detached(priority: .userInitiated) {
            session.stopRunning()
        }
    }
}

extension MetadataScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        for object in metadataObjects {
            guard
                let readable = object as? AVMetadataMachineReadableCodeObject,
                readable.type == .qr,
                let payload = readable.stringValue
            else { continue }
            onScan?(payload)
        }
    }
}
