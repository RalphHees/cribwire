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

        if settings.noise.isEnabled {
            startAudioMonitor()
        } else {
            audioMonitor?.stop()
            audioMonitor = nil
            isNoiseDetectionUnavailable = false
            currentLevelDBFS = AWeightingFilter.silenceFloorDB
            noise.resetWindowState()
        }

        if !settings.movement.isEnabled {
            movement.resetFrameState()
        }
        isMovementDetectionRunning = settings.movement.isEnabled
    }

    private func startAudioMonitor() {
        guard audioMonitor == nil else { return }
        let monitor = AudioLevelMonitor { [weak self] level in
            self?.ingest(levelDBFS: level)
        }
        do {
            try monitor.start()
            audioMonitor = monitor
            isNoiseDetectionUnavailable = false
        } catch {
            isNoiseDetectionUnavailable = true
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
