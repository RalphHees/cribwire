import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The payload the Camera seals with `K_evt` and posts to `/v1/events`
/// (`security.md` §5).
///
/// The wire form is pinned by the event vector in
/// `shared/test-vectors/kidscam-v1.json`:
///
/// ```json
/// {"type":"noise","ts":1754850000}
/// ```
///
/// That is the entire content of a KidsCam push. The backend and Apple see only
/// its ciphertext and a generic alert key; the Viewer's Notification Service
/// Extension opens it to decide which sentence to show.
public struct DetectionEvent: Codable, Equatable, Sendable {

    public enum Kind: String, Codable, Equatable, Sendable {
        case noise
        case motion
        /// `security.md` §5 spells this one with an underscore.
        case lowBattery = "low_battery"
    }

    public let type: Kind
    /// Unix seconds.
    public let ts: Int

    public init(type: Kind, ts: Int) {
        self.type = type
        self.ts = ts
    }

    public init(type: Kind, at date: Date) {
        self.init(type: type, ts: Int(date.timeIntervalSince1970.rounded(.down)))
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(ts))
    }

    // MARK: - Sealing

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Seals the event for `POST /v1/events`.
    ///
    /// AAD is `<pairingId>|event`, so an event ciphertext can never be replayed
    /// into the signaling channel or vice versa.
    public func sealed(using eventKey: SymmetricKey, pairingID: UUID) throws -> String {
        let plaintext = try Self.encoder.encode(self)
        return try SealedEnvelope.seal(
            plaintext,
            using: eventKey,
            associatedData: .event(pairingID: pairingID)
        )
    }

    /// Opens a sealed event — the Notification Service Extension's whole job.
    ///
    /// Throws `CryptoError.authenticationFailed` for a wrong key, a wrong
    /// pairing or tampered bytes, all indistinguishable on purpose. The caller
    /// must respond to *any* failure with the generic alert text
    /// (`security.md` §5).
    public static func open(
        sealed sealedBase64: String,
        using eventKey: SymmetricKey,
        pairingID: UUID
    ) throws -> DetectionEvent {
        let plaintext = try SealedEnvelope.open(
            sealedBase64,
            using: eventKey,
            associatedData: .event(pairingID: pairingID)
        )
        do {
            return try JSONDecoder().decode(DetectionEvent.self, from: plaintext)
        } catch {
            throw CryptoError.malformedEnvelope
        }
    }
}

/// Decides when the Camera sends the low-battery event (`ios-app.md` §2.3).
///
/// A warning appears on screen below 20 %, and Viewers are told at 15 %. The
/// event must fire once, not once a minute while the level hovers on the
/// boundary, so it re-arms only after the battery recovers past the warning
/// level or the device is put on a charger.
public struct LowBatteryMonitor: Equatable, Sendable {
    /// Show "plug in the charger" on the Camera below this.
    public static let warningLevel = 0.20
    /// Push a `low_battery` event to Viewers at this level.
    public static let eventLevel = 0.15

    private var hasFired = false

    public init() {}

    /// - Parameters:
    ///   - level: battery level, `0...1`. Pass a negative value when it is
    ///     unknown (`UIDevice` reports −1 before monitoring is enabled).
    ///   - isCharging: charging or full.
    /// - Returns: `true` exactly once per discharge below the event level.
    public mutating func ingest(level: Double, isCharging: Bool) -> Bool {
        guard level >= 0 else { return false }

        if isCharging || level > Self.warningLevel {
            hasFired = false
            return false
        }
        guard level <= Self.eventLevel, !hasFired else { return false }
        hasFired = true
        return true
    }

    /// Whether the on-screen "plug in the charger" warning should be visible.
    public static func showsWarning(level: Double, isCharging: Bool) -> Bool {
        guard level >= 0, !isCharging else { return false }
        return level <= warningLevel
    }
}
