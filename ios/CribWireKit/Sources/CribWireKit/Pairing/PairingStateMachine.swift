import Foundation

/// Pure state machines for the QR pairing flow (`ios-app.md` §2.2,
/// `security.md` §3.3).
///
/// Both machines are plain values: they own no timers, no network and no keys.
/// The view models feed them events (a tick, a server response, a tap) and act on
/// the returned effects. That keeps the entire pairing flow — including every
/// expiry and failure path — unit-testable without a device.

// MARK: - Shared vocabulary

/// Why a pairing attempt stopped.
public enum PairingFailure: Equatable, Sendable {
    /// The QR's pairing expired before anyone claimed it (server-side TTL,
    /// 10 minutes — `security.md` §3.1).
    case expired
    /// The user backed out.
    case cancelled
    /// The scanned code was not a valid CribWire v1 pairing payload.
    case invalidQRCode(QRPayload.ParseError)
    /// The camera already has the maximum number of viewers (`ios-app.md` §2.2).
    case viewerLimitReached
    /// The user said the two codes did not match — a possible QR substitution
    /// attack, so this is a hard stop, not a retry.
    case sasMismatch
    /// Backend or transport failure. `message` is safe to show; it never carries
    /// key material.
    case backend(message: String)
}

/// Timing constants pinned by `security.md` §3.1.
public enum PairingTiming {
    /// A fresh secret + QR every 2 minutes while the code is on screen.
    public static let qrRegenerationInterval: TimeInterval = 120
    /// An unclaimed pairing dies server-side after 10 minutes.
    public static let pairingTTL: TimeInterval = 600
    /// Maximum viewers per camera.
    public static let maxViewersPerCamera = 5
}

/// One registered-but-unclaimed pairing the camera is willing to accept a claim
/// on.
///
/// The camera rotates the QR every 2 minutes, but a viewer may have scanned the
/// previous code moments before the rotation. Rather than invalidating it — which
/// would fail an honest viewer mid-claim — the camera keeps every candidate alive
/// until its own server-side TTL runs out.
public struct PairingCandidate: Equatable, Sendable {
    public let pairingID: UUID
    /// When this candidate was registered with the backend.
    public let createdAt: Date
    /// `createdAt + pairingTTL`.
    public let expiresAt: Date

    public init(pairingID: UUID, createdAt: Date) {
        self.pairingID = pairingID
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(PairingTiming.pairingTTL)
    }

    public func isLive(at now: Date) -> Bool { now < expiresAt }
}

// MARK: - Camera

/// Camera side: generating → displaying → claimed (show SAS) → active.
public struct CameraPairingStateMachine: Equatable, Sendable {

    public struct DisplayState: Equatable, Sendable {
        /// Every candidate still live, oldest first. The last one is the code
        /// currently on screen.
        public fileprivate(set) var candidates: [PairingCandidate]
        /// When the on-screen code should be replaced by a fresh secret.
        public fileprivate(set) var regeneratesAt: Date

        /// The code currently on screen. Never `nil` while the state is
        /// `.displaying`, but optional so no code path can trap.
        public var current: PairingCandidate? { candidates.last }

        public init(candidates: [PairingCandidate], regeneratesAt: Date) {
            self.candidates = candidates
            self.regeneratesAt = regeneratesAt
        }
    }

    public struct ClaimedState: Equatable, Sendable {
        public let pairingID: UUID
        public let viewerDeviceID: String
        /// The code this device derived locally from `K_sas`. Shown next to the
        /// viewer's copy for the human comparison.
        public let sasCode: SASCode

        public init(pairingID: UUID, viewerDeviceID: String, sasCode: SASCode) {
            self.pairingID = pairingID
            self.viewerDeviceID = viewerDeviceID
            self.sasCode = sasCode
        }
    }

    public struct ActiveState: Equatable, Sendable {
        public let pairingID: UUID
        public let viewerDeviceID: String

        public init(pairingID: UUID, viewerDeviceID: String) {
            self.pairingID = pairingID
            self.viewerDeviceID = viewerDeviceID
        }
    }

    public enum State: Equatable, Sendable {
        /// Nothing started yet.
        case idle
        /// Generating a secret and registering the pairing with the backend.
        case generating
        /// QR on screen, waiting for a claim.
        case displaying(DisplayState)
        /// A viewer claimed the pairing; both screens show the SAS.
        case claimed(ClaimedState)
        /// Pairing complete and persisted.
        case active(ActiveState)
        /// Terminal failure; the user restarts from `idle`.
        case failed(PairingFailure)
    }

    public enum Event: Equatable, Sendable {
        /// User opened the pairing screen.
        case start
        /// A pairing was successfully registered with the backend.
        case registered(pairingID: UUID, at: Date)
        /// `POST /v1/pairings` failed.
        case registrationFailed(message: String)
        /// Wall-clock advanced (driven by a 1 s UI timer).
        case tick(now: Date)
        /// The backend told us over the socket that a viewer claimed `pairingID`.
        case viewerClaimed(pairingID: UUID, viewerDeviceID: String, sasCode: SASCode)
        /// The viewer confirmed the codes match.
        case viewerConfirmed
        /// The user backed out of the pairing screen.
        case cancel
    }

    /// Side effects the view model is expected to perform.
    public enum Effect: Equatable, Sendable {
        /// Generate a new root secret, register it, and report back with
        /// `.registered`. Also emitted for every rotation.
        case generateAndRegisterPairing
        /// Stop showing the QR (SAS is up, or we failed).
        case stopDisplayingQRCode
        /// Drop these expired candidates locally; the server expires them too.
        case discardCandidates([UUID])
        /// Persist the finished pairing's keys to the Keychain.
        case persistPairing(pairingID: UUID, viewerDeviceID: String)
    }

    public private(set) var state: State

    public init(state: State = .idle) {
        self.state = state
    }

    @discardableResult
    public mutating func apply(_ event: Event) -> [Effect] {
        switch (state, event) {

        // Start / restart
        case (.idle, .start), (.failed, .start):
            state = .generating
            return [.generateAndRegisterPairing]

        case (.generating, .registered(let pairingID, let now)):
            let candidate = PairingCandidate(pairingID: pairingID, createdAt: now)
            state = .displaying(
                DisplayState(
                    candidates: [candidate],
                    regeneratesAt: now.addingTimeInterval(PairingTiming.qrRegenerationInterval)
                )
            )
            return []

        case (.generating, .registrationFailed(let message)):
            state = .failed(.backend(message: message))
            return [.stopDisplayingQRCode]

        // Rotation: a new secret is registered while older ones stay claimable.
        case (.displaying(var display), .registered(let pairingID, let now)):
            display.candidates.append(PairingCandidate(pairingID: pairingID, createdAt: now))
            display.regeneratesAt = now.addingTimeInterval(PairingTiming.qrRegenerationInterval)
            state = .displaying(display)
            return []

        case (.displaying, .registrationFailed(let message)):
            // Rotation failed. The code on screen is still valid until its own
            // TTL, so this is not fatal — but the user needs to know.
            state = .failed(.backend(message: message))
            return [.stopDisplayingQRCode]

        case (.displaying(var display), .tick(let now)):
            var effects: [Effect] = []

            let expired = display.candidates.filter { !$0.isLive(at: now) }
            if !expired.isEmpty {
                display.candidates.removeAll { !$0.isLive(at: now) }
                effects.append(.discardCandidates(expired.map(\.pairingID)))
            }

            guard !display.candidates.isEmpty else {
                state = .failed(.expired)
                return effects + [.stopDisplayingQRCode]
            }

            if now >= display.regeneratesAt {
                // Push the deadline out so a burst of ticks cannot queue several
                // registrations; the real reset happens on `.registered`.
                display.regeneratesAt = now.addingTimeInterval(
                    PairingTiming.qrRegenerationInterval
                )
                effects.append(.generateAndRegisterPairing)
            }

            state = .displaying(display)
            return effects

        case (.displaying(let display), .viewerClaimed(let pairingID, let deviceID, let sas)):
            // Accept a claim on any candidate that has not expired, not just the
            // code currently on screen.
            guard display.candidates.contains(where: { $0.pairingID == pairingID }) else {
                return []
            }
            state = .claimed(
                ClaimedState(pairingID: pairingID, viewerDeviceID: deviceID, sasCode: sas)
            )
            let stale = display.candidates
                .map(\.pairingID)
                .filter { $0 != pairingID }
            return stale.isEmpty
                ? [.stopDisplayingQRCode]
                : [.stopDisplayingQRCode, .discardCandidates(stale)]

        case (.claimed(let claimed), .viewerConfirmed):
            state = .active(
                ActiveState(pairingID: claimed.pairingID, viewerDeviceID: claimed.viewerDeviceID)
            )
            return [
                .persistPairing(
                    pairingID: claimed.pairingID,
                    viewerDeviceID: claimed.viewerDeviceID
                )
            ]

        // Cancellation from any non-terminal state.
        case (.generating, .cancel), (.displaying, .cancel), (.claimed, .cancel):
            state = .failed(.cancelled)
            return [.stopDisplayingQRCode]

        default:
            return []
        }
    }
}

// MARK: - Viewer

/// Viewer side: scanning → claiming → confirming SAS → active.
public struct ViewerPairingStateMachine: Equatable, Sendable {

    public struct ClaimingState: Equatable, Sendable {
        public let pairingID: UUID
        /// `nil` for a local-network-only pairing.
        public let apiBaseURL: URL?

        public init(pairingID: UUID, apiBaseURL: URL?) {
            self.pairingID = pairingID
            self.apiBaseURL = apiBaseURL
        }
    }

    public struct ConfirmingState: Equatable, Sendable {
        public let pairingID: UUID
        /// `nil` for a local-network-only pairing.
        public let apiBaseURL: URL?
        /// Derived locally from `K_sas` — never received from the network.
        public let sasCode: SASCode

        public init(pairingID: UUID, apiBaseURL: URL?, sasCode: SASCode) {
            self.pairingID = pairingID
            self.apiBaseURL = apiBaseURL
            self.sasCode = sasCode
        }
    }

    public struct ActiveState: Equatable, Sendable {
        public let pairingID: UUID

        public init(pairingID: UUID) {
            self.pairingID = pairingID
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Camera is up, waiting for a QR in frame.
        case scanning
        /// Deriving keys and calling `POST /v1/pairings/{id}/claim`.
        case claiming(ClaimingState)
        /// Showing the 6 digits for the user to compare with the camera's screen.
        case confirmingSAS(ConfirmingState)
        case active(ActiveState)
        case failed(PairingFailure)
    }

    public enum Event: Equatable, Sendable {
        case startScanning
        /// A QR was decoded and parsed successfully.
        case scanned(pairingID: UUID, apiBaseURL: URL?)
        /// A QR was decoded but was not a valid v1 pairing payload.
        case scanRejected(QRPayload.ParseError)
        /// The claim succeeded; `sasCode` was derived locally from `K_sas`.
        case claimSucceeded(sasCode: SASCode)
        case claimFailed(PairingFailure)
        /// User tapped "Codes match — Pair".
        case userConfirmedSAS
        /// User tapped cancel on the SAS screen because the codes differed.
        case userRejectedSAS
        case cancel
    }

    public enum Effect: Equatable, Sendable {
        /// Derive keys from the scanned secret and POST the claim.
        case claimPairing(pairingID: UUID, apiBaseURL: URL?)
        case stopScanning
        /// Persist keys to the Keychain — only after the human confirmed the SAS.
        case persistPairing(pairingID: UUID)
        /// Throw away the scanned secret without persisting anything.
        case discardScannedSecret
    }

    public private(set) var state: State

    public init(state: State = .idle) {
        self.state = state
    }

    @discardableResult
    public mutating func apply(_ event: Event) -> [Effect] {
        switch (state, event) {

        case (.idle, .startScanning), (.failed, .startScanning):
            state = .scanning
            return []

        case (.scanning, .scanned(let pairingID, let apiBaseURL)):
            state = .claiming(ClaimingState(pairingID: pairingID, apiBaseURL: apiBaseURL))
            return [.stopScanning, .claimPairing(pairingID: pairingID, apiBaseURL: apiBaseURL)]

        case (.scanning, .scanRejected):
            // Stay in `.scanning`: an unrelated QR drifting through the frame
            // should not tear the screen down. The view model surfaces a hint.
            return []

        case (.claiming(let claiming), .claimSucceeded(let sasCode)):
            state = .confirmingSAS(
                ConfirmingState(
                    pairingID: claiming.pairingID,
                    apiBaseURL: claiming.apiBaseURL,
                    sasCode: sasCode
                )
            )
            return []

        case (.claiming, .claimFailed(let failure)):
            state = .failed(failure)
            return [.discardScannedSecret]

        case (.confirmingSAS(let confirming), .userConfirmedSAS):
            state = .active(ActiveState(pairingID: confirming.pairingID))
            return [.persistPairing(pairingID: confirming.pairingID)]

        case (.confirmingSAS, .userRejectedSAS):
            state = .failed(.sasMismatch)
            return [.discardScannedSecret]

        case (.scanning, .cancel):
            state = .failed(.cancelled)
            return [.stopScanning, .discardScannedSecret]

        case (.claiming, .cancel), (.confirmingSAS, .cancel):
            state = .failed(.cancelled)
            return [.discardScannedSecret]

        default:
            return []
        }
    }
}
