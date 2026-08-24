import Foundation
import CribWireKit
import SwiftUI

/// Runs the Camera's detectors and turns what they decide into sealed events.
///
/// The detectors themselves are pure values in `CribWireKit` and stay that way;
/// this owns the parts that cannot be: the microphone, the frame feed, the clock,
/// the battery, and the one network call. That split is why every threshold and
/// every cooldown rule is unit-tested and none of it is re-implemented here.
///
/// The privacy property it has to hold (`security.md` §5) is that the server
/// learns *that* something happened and nothing else. The event is sealed with
/// `K_evt` before it leaves, so the backend fans out a ciphertext it cannot read
/// and Apple displays a generic string — the Viewer app is the only thing in the
/// chain that can say "noise" rather than "activity".
@MainActor
@Observable
final class DetectionCoordinator {

    /// Live room level in dBFS, for the settings screen's meter and the Camera's
    /// status readout.
    private(set) var currentLevelDBFS = AWeightingFilter.silenceFloorDB
    /// The last event this Camera sent, for the status screen.
    private(set) var lastEvent: DetectionEvent?
    /// Set when the microphone could not be opened. Surfaced rather than
    /// swallowed: a noise detector that is silently dead is worse than one the
    /// user knows is off.
    private(set) var isNoiseDetectionUnavailable = false
    /// True while the movement detector is consuming frames.
    private(set) var isMovementDetectionRunning = false

    private var noise: NoiseDetector
    private var movement: MovementDetector
    private var battery = LowBatteryMonitor()
    private var settings: DetectionSettings

    /// Holds the microphone open even with noise alerts switched off.
    ///
    /// Set while the Camera's screen is off, and this is what keeps the whole app
    /// alive there. `UIBackgroundModes: audio` sustains a backgrounded app only
    /// while it is actually doing audio I/O; a Camera with nobody watching and
    /// noise alerts off is doing none, so iOS suspended it seconds after the power
    /// button and took the signalling socket, every Viewer command and the
    /// detectors down with it. One running input tap is enough to prevent that.
    ///
    /// Deliberately not left on all the time. The recording indicator is a promise
    /// to the person in the room, and a Camera sitting in the foreground with
    /// alerts off has no business holding the microphone — so it is taken for
    /// exactly as long as the screen is dark and given straight back.
    ///
    /// The levels it produces cost nothing: `ingest(levelDBFS:)` already discards
    /// them when noise alerts are off, so nothing downstream can fire on them.
    ///
    /// Computed over a backing store for the same reason as
    /// `NurseryController.hasConnectedViewers`: `@Observable` rewrites stored
    /// properties into accessors, and Swift will not accept `didSet` on top of
    /// those.
    var isKeepAliveRequired: Bool {
        get { storedIsKeepAliveRequired }
        set {
            guard newValue != storedIsKeepAliveRequired else { return }
            storedIsKeepAliveRequired = newValue
            refreshAudioMonitor()
        }
    }

    private var storedIsKeepAliveRequired = false

    private var audioMonitor: AudioLevelMonitor?
    private let record: PairingRecord
    private let services: AppServices
    private let now: () -> Date

    /// Guards against two events racing out of the two detectors at once. The
    /// per-pairing rate limit on the backend is one event per 30 s, so a double
    /// send is a wasted request and a lost alert.
    private var isSending = false

    init(
        record: PairingRecord,
        services: AppServices,
        settings: DetectionSettings? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        let resolved = settings ?? services.detectionSettings
        self.record = record
        self.services = services
        self.settings = resolved
        self.now = now
        self.noise = NoiseDetector(settings: resolved.noise, cooldown: resolved.cooldown)
        self.movement = MovementDetector(
            settings: resolved.movement,
            cooldown: resolved.cooldown
        )
    }

    // MARK: - Lifecycle

    func start() {
        apply(settings)
    }

    func stop() {
        audioMonitor?.stop()
        audioMonitor = nil
        isMovementDetectionRunning = false
    }

    /// Re-reads the settings and starts or stops each detector to match.
    ///
    /// Called whenever the alerts screen changes something, so a user who turns
    /// noise alerts on does not have to restart the Camera for it to take effect.
    func apply(_ settings: DetectionSettings) {
        self.settings = settings
        noise.settings = settings.noise
        noise.cooldown = settings.cooldown
        movement.settings = settings.movement
        movement.cooldown = settings.cooldown

        if !settings.noise.isEnabled {
            currentLevelDBFS = AWeightingFilter.silenceFloorDB
            noise.resetWindowState()
        }
        refreshAudioMonitor()

        if !settings.movement.isEnabled {
            movement.resetFrameState()
        }
        isMovementDetectionRunning = settings.movement.isEnabled
    }

    /// Starts or stops the one microphone client to match what needs it.
    ///
    /// Two independent reasons to hold the input, and only one of them is
    /// detection — see `isKeepAliveRequired`. They share a single
    /// `AudioLevelMonitor` rather than opening the input twice, because two
    /// `AVAudioEngine`s on one input is exactly the conflict the monitor's own
    /// documentation warns about.
    private func refreshAudioMonitor() {
        guard settings.noise.isEnabled || isKeepAliveRequired else {
            audioMonitor?.stop()
            audioMonitor = nil
            isNoiseDetectionUnavailable = false
            return
        }
        guard audioMonitor == nil else {
            // Already running. The failure flag still has to be re-derived: a tap
            // opened purely to keep the app alive says nothing about whether noise
            // alerts work, and noise alerts that have just been switched on over a
            // working tap do.
            isNoiseDetectionUnavailable = false
            return
        }

        let monitor = AudioLevelMonitor { [weak self] level in
            self?.ingest(levelDBFS: level)
        }
        do {
            try monitor.start()
            audioMonitor = monitor
            isNoiseDetectionUnavailable = false
        } catch {
            // Only reported when somebody asked for noise alerts. A keep-alive
            // that could not open the microphone is a battery-life problem, not a
            // detector the Viewer needs warning about — saying "microphone
            // unavailable" on a Camera whose alerts are off would be a warning
            // about nothing.
            isNoiseDetectionUnavailable = settings.noise.isEnabled
        }
    }

    // MARK: - Feeds

    func ingest(levelDBFS: Double) {
        currentLevelDBFS = levelDBFS
        guard settings.noise.isEnabled else { return }
        if case .triggered = noise.ingest(levelDBFS: levelDBFS, at: now()) {
            send(.noise)
        }
    }

    /// Fed from the capture tap, already downsampled to the detector's size.
    func ingest(_ frame: LumaFrame) {
        guard settings.movement.isEnabled else { return }
        if case .triggered = movement.ingest(frame, at: now()) {
            send(.motion)
        }
    }

    /// Battery level, `0...1`, negative when unknown.
    ///
    /// Unlike the two detectors this has no enable toggle: a Camera that is about
    /// to die is something a Viewer always needs to hear about, and it is not a
    /// detection of anything in the room.
    func ingest(batteryLevel: Double, isCharging: Bool) {
        guard battery.ingest(level: batteryLevel, isCharging: isCharging) else { return }
        send(.lowBattery)
    }

    // MARK: - Sending

    private func send(_ kind: DetectionEvent.Kind) {
        guard !isSending else { return }
        isSending = true
        let event = DetectionEvent(type: kind, at: now())

        Task { [weak self] in
            guard let self else { return }
            await self.post(event)
            self.isSending = false
        }
    }

    private func post(_ event: DetectionEvent) async {
        guard let eventKey = (try? await services.secrets.eventKey(for: record.id)) ?? nil,
              let client = (try? await services.makeAPIClient(for: record)) ?? nil,
              let ciphertext = try? event.sealed(using: eventKey, pairingID: record.id)
        else {
            return
        }

        do {
            try await client.postEvent(ciphertext: ciphertext)
            lastEvent = event
        } catch {
            // A dropped event is not worth a retry: by the time a retry landed
            // the alert would be stale, and the backend's own rate limit means a
            // second attempt is likely to be refused anyway. The next trigger
            // after the cooldown is the retry.
        }
    }
}
