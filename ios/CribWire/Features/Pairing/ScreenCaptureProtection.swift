import SwiftUI
import UIKit

/// Screen-capture protection for the QR view (`security.md` §7).
///
/// iOS gives us no supported "do not capture this view" API — `preventsCapture`
/// exists only on `AVPlayerItem` for FairPlay content, and there is no SwiftUI
/// equivalent. CribWire therefore uses two independent mitigations:
///
/// 1. `ScreenCaptureMonitor` — `UIScreen.isCaptured` is public API and turns true
///    for screen recording, AirPlay mirroring and QuickTime capture. When it
///    does, the QR is replaced with an explanation. This is the layer we rely on.
/// 2. `SecureCaptureContainer` — hosts the content inside the render layer of a
///    secure `UITextField`, which the window server omits from screenshots and
///    recordings. This is the well-known "secure text field" trick; it depends on
///    an implementation detail, so it degrades to a plain container if the view
///    hierarchy ever changes, and counts as defence in depth only.
///
/// Neither stops someone photographing the screen with another phone — which is
/// why the QR screen also states, in plain words, what the code contains.

// MARK: - Capture monitor

@MainActor
@Observable
final class ScreenCaptureMonitor {
    /// True while the screen is being recorded or mirrored.
    private(set) var isCaptured: Bool = false

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()

        let notifications: [Notification.Name] = [
            UIScreen.capturedDidChangeNotification,
            // Mirroring to a newly connected display is also a capture path.
            UIScreen.didConnectNotification,
            UIApplication.didBecomeActiveNotification
        ]

        for name in notifications {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            observers.append(observer)
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func refresh() {
        // `UIScreen.main` is soft-deprecated on iOS 16, but it remains the only
        // way to ask about capture state without a view in hand, and CribWire is
        // a single-window app.
        isCaptured = UIScreen.main.isCaptured
    }
}

// MARK: - Secure container

/// Wraps its content in the render layer of a secure `UITextField`.
struct SecureCaptureContainer<Content: View>: UIViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> UIView {
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.host = host

        let container = SecureHostView()
        container.embed(host.view)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.host?.rootView = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: UIHostingController<Content>?
    }
}

/// Performs the secure-field trick, with a plain fallback if the private canvas
/// view cannot be found.
private final class SecureHostView: UIView {
    private let textField = UITextField()

    func embed(_ view: UIView) {
        let target = makeSecureCanvas() ?? self

        target.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: target.topAnchor),
            view.bottomAnchor.constraint(equalTo: target.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: target.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: target.trailingAnchor)
        ])
    }

    /// Installs the secure text field and returns the canvas view it renders
    /// into, or `nil` if the hierarchy is not what we expect.
    private func makeSecureCanvas() -> UIView? {
        textField.isSecureTextEntry = true
        textField.isUserInteractionEnabled = false
        textField.translatesAutoresizingMaskIntoConstraints = false

        guard let canvas = textField.subviews.first else { return nil }
        canvas.subviews.forEach { $0.removeFromSuperview() }
        canvas.isUserInteractionEnabled = true

        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        return canvas
    }
}
