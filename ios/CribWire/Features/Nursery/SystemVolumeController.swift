import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// Reads and sets the Camera device's output volume.
///
/// **Why the device's volume and not the player's.** Neither MusicKit nor TIDAL's
/// SDK exposes a per-app gain — there is no "make CribWire's music quieter" knob
/// to turn. That turns out to be the right answer anyway: a Viewer asking for less
/// volume means *less sound in the nursery*, and the nursery hears the phone's
/// speaker, not an app's mixer.
///
/// **How.** Reading is public API: `AVAudioSession.outputVolume`, observed with
/// KVO so a hardware button press on the Camera reaches the Viewer's slider.
/// Writing has no public API at all, so this does what every app that needs it has
/// done for a decade: it hosts an `MPVolumeView` off-screen and moves the
/// `UISlider` inside it. Nothing here is private API — `MPVolumeView` and
/// `UISlider.value` are both public — but the *arrangement* of subviews inside
/// `MPVolumeView` is Apple's, not ours, so every step is optional and the whole
/// thing degrades to "volume is readable but not settable" if that arrangement
/// ever changes. `canSetVolume` reports which of those the app is in, and the
/// Viewer hides the slider rather than showing one that does nothing.
///
/// One consequence worth stating plainly: this moves the *system* volume, so it
/// also changes how loud a Viewer's push-to-talk comes out of the Camera. That is
/// the same trade the hardware buttons on the phone make, and it is what "turn it
/// down in there" means.
@MainActor
final class SystemVolumeController {

    /// Current output volume, `0...1`.
    private(set) var volume: Double

    /// Called when the volume changes for any reason — this controller, the
    /// Camera's hardware buttons, or a route change.
    var onChange: ((Double) -> Void)?

    private let session: AVAudioSession
    private let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private var observation: NSKeyValueObservation?

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        self.volume = Double(session.outputVolume)
    }

    // No `deinit`: `NSKeyValueObservation` invalidates itself when it is
    // deallocated, and reaching for an isolated property from a deinitialiser is
    // exactly the kind of thing that stops compiling under stricter concurrency.

    /// Attaches the hidden volume view and starts observing.
    ///
    /// Called when a Viewer is being served, not at launch: an `MPVolumeView` in
    /// the hierarchy is worth nothing on a Camera nobody is watching.
    func start() {
        attachHost()
        observation?.invalidate()
        // KVO fires on whatever thread changed the value, so everything this
        // controller owns is touched only after the hop back.
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let level = change.newValue else { return }
            Task { @MainActor in
                self?.apply(observedVolume: Double(level))
            }
        }
        volume = Double(session.outputVolume)
    }

    /// - Note: ignores changes smaller than the rounding on the Viewer's slider.
    ///   `set(volume:)` itself moves the system volume, so without this every
    ///   drag would echo back as a "someone else changed it" notification.
    private func apply(observedVolume level: Double) {
        guard abs(level - volume) > 0.001 else { return }
        volume = level
        onChange?(level)
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        volumeView.removeFromSuperview()
    }

    /// Whether `set(volume:)` can actually do anything on this OS build.
    var canSetVolume: Bool { slider != nil }

    /// - Parameter level: clamped to `0...1`.
    func set(volume level: Double) {
        let clamped = min(max(level, 0), 1)
        guard let slider else { return }
        // `setValue(_:animated:)` alone moves the knob without telling the system;
        // the value-changed action is what actually applies it.
        slider.setValue(Float(clamped), animated: false)
        slider.sendActions(for: .valueChanged)
        volume = clamped
    }

    private var slider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    /// Puts the volume view in a real window, off-screen and untouchable.
    ///
    /// It has to be in the hierarchy: `MPVolumeView` builds its slider when it
    /// moves to a window, so one that was merely allocated has no slider to move
    /// and `canSetVolume` would be false for the whole session.
    private func attachHost() {
        guard volumeView.superview == nil else { return }
        guard let window = Self.activeWindow() else { return }
        volumeView.alpha = 0.001
        volumeView.isUserInteractionEnabled = false
        volumeView.showsRouteButton = false
        // Off the edge of the screen rather than hidden: a hidden view is not
        // laid out, and an unlaid-out MPVolumeView never builds its slider.
        volumeView.frame = CGRect(x: -1_000, y: -1_000, width: 1, height: 1)
        window.addSubview(volumeView)
    }

    private static func activeWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
