import Foundation
import CribWireKit
import SwiftUI

/// Drives the Camera's pairing screen: generate a secret, register it, render the
/// QR, rotate it every two minutes, and hand over to the SAS screen when a viewer
/// claims it.
///
/// All decisions live in `CameraPairingStateMachine`; this type only performs the
/// effects the machine asks for. That keeps the timing and expiry rules
/// unit-tested and keeps this file free of branching logic.
@MainActor
@Observable
final class CameraPairingViewModel {

    private(set) var state: CameraPairingStateMachine.State = .idle
    /// The URL currently encoded in the QR. Held only while it is on screen.
    private(set) var qrURLString: String?
    /// Seconds until the code is replaced.
    private(set) var secondsUntilRegeneration: Int = 0
    private(set) var errorMessage: String?

    /// The SAS this device derived for the pairing being confirmed.
    var sasCode: SASCode? {
        if case .claimed(let claimed) = state { return claimed.sasCode }
        return nil
    }

    var isDisplayingQRCode: Bool {
        if case .displaying = state { return true }
        return false
    }

    private var machine = CameraPairingStateMachine()
    /// Pairings that are still claimable. Cleared aggressively: a secret that is
    /// no longer claimable is a liability.
    ///
    /// One entry per candidate, each with its own socket — the camera rotates the
    /// QR every two minutes but honours a claim on any code still inside its
    /// ten-minute TTL, so it has to be listening on all of them at once.
    private var candidates: [UUID: Candidate] = [:]
    private var tickTask: Task<Void, Never>?

    /// A registered-but-unclaimed pairing, and the socket waiting to hear it
    /// claimed.
    private struct Candidate {
        let rootSecret: RootSecret
        /// Server path: the socket that hears the claim. Nil offline.
        let link: PairingSignalingLink?
        /// Local path: the Bonjour advertiser waiting for a Viewer to dial in.
        let host: LocalPairingHost?

        @MainActor
        func stop() {
            link?.stop()
            host?.stop()
        }
    }

    /// Pair without a backend, over the local network only.
    ///
    /// Off by default: the ordinary flow is the one most people want, and this
    /// trades push alerts and remote viewing for working with the internet
    /// unplugged (`docs/TASKS.md` Phase 5).
    var isLocalOnly = false

    private let services: AppServices
    private let apiBaseURL: URL?
    /// Set by tests; otherwise the token is read from the notification
    /// coordinator when the request is actually made, because APNs registration
    /// completes asynchronously and may well finish after this screen appears.
    private let overriddenAPNSToken: String?
    private let overriddenAPNSEnvironment: API.APNSEnvironment?

    /// Empty when this device has no token yet — the backend accepts that and
    /// simply has nothing to push to until the token is rotated in.
    private var apnsToken: String { overriddenAPNSToken ?? services.notifications.apnsToken ?? "" }
    private var apnsEnvironment: API.APNSEnvironment {
        overriddenAPNSEnvironment ?? services.notifications.apnsEnvironment
    }

    init(
        services: AppServices,
        apnsToken: String? = nil,
        apnsEnvironment: API.APNSEnvironment? = nil
    ) {
        self.services = services
        self.apiBaseURL = services.configuration.defaultAPIBaseURL
        self.overriddenAPNSToken = apnsToken
        self.overriddenAPNSEnvironment = apnsEnvironment
    }

    // MARK: - Lifecycle

    func start() {
        // A local-only pairing needs no backend, so the missing-configuration
        // check applies only to the ordinary path.
        guard isLocalOnly || apiBaseURL != nil else {
            errorMessage = String(localized: "No backend is configured in this build.")
            return
        }
        errorMessage = nil
        dispatch(machine.apply(.start))
        startTicking()
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        dispatch(machine.apply(.cancel))
        discardAllSecrets()
    }

    /// Called when the user taps "Codes match" — on the Camera this is only an
    /// acknowledgement; the Viewer's confirmation is what activates the pairing.
    func confirmSAS() {
        dispatch(machine.apply(.viewerConfirmed))
    }

    /// A viewer claimed `pairingID` and connected to its signaling socket
    /// (`security.md` §3.3 step 2).
    ///
    /// The SAS is derived here, from the secret this device generated — the
    /// server's announcement supplies only the viewer's id, and is a prompt to
    /// show the code, never a source of it.
    func handleViewerClaim(pairingID: UUID, viewerDeviceID: String) {
        guard let candidate = candidates[pairingID] else { return }
        dispatch(
            machine.apply(
                .viewerClaimed(
                    pairingID: pairingID,
                    viewerDeviceID: viewerDeviceID,
                    sasCode: candidate.rootSecret.deriveKeys().sasCode
                )
            )
        )
    }

    /// Presence on a candidate's socket. Only a viewer means a claim: the server
    /// also announces the camera itself back to a socket that reconnected.
    private func handlePeerOnline(_ presence: SignalingPresence, pairingID: UUID) {
        guard presence.role == .viewer, let viewerDeviceID = presence.deviceID else {
            return
        }
        handleViewerClaim(pairingID: pairingID, viewerDeviceID: viewerDeviceID)
    }

    // MARK: - Timer

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.tick(now: Date())
            }
        }
    }

    private func tick(now: Date) {
        dispatch(machine.apply(.tick(now: now)))

        if case .displaying(let display) = machine.state {
            secondsUntilRegeneration = max(
                0,
                Int(display.regeneratesAt.timeIntervalSince(now).rounded(.up))
            )
        } else {
            secondsUntilRegeneration = 0
        }
        state = machine.state
    }

    // MARK: - Effects

    private func dispatch(_ effects: [CameraPairingStateMachine.Effect]) {
        state = machine.state

        for effect in effects {
            switch effect {
            case .generateAndRegisterPairing:
                Task { await self.registerNewPairing() }

            case .stopDisplayingQRCode:
                qrURLString = nil

            case .discardCandidates(let pairingIDs):
                for pairingID in pairingIDs {
                    candidates.removeValue(forKey: pairingID)?.stop()
                }

            case .persistPairing(let pairingID, let viewerDeviceID):
                Task { await self.persist(pairingID: pairingID, viewerDeviceID: viewerDeviceID) }
            }
        }
    }

    private func registerNewPairing() async {
        if isLocalOnly {
            await registerLocalPairing()
            return
        }
        guard let apiBaseURL else { return }

        do {
            // Fresh id *and* fresh secret for every attempt (security.md §3.1).
            let pairingID = UUID()
            let rootSecret = try RootSecret.generate()
            let keys = rootSecret.deriveKeys()

            let client = APIClient(
                configuration: .init(baseURL: apiBaseURL, pairingID: pairingID),
                keys: keys,
                transport: services.makeTransport()
            )
            // Protocol 1.1: the camera mints its own key and registers it in the
            // bootstrap create call, then signs later requests with it — so a
            // viewer holding the pairing-wide K_auth cannot act as this camera.
            let deviceKey = try DeviceKey.generate()
            let response = try await client.createPairing(
                deviceKey: deviceKey,
                apnsToken: apnsToken,
                apnsEnvironment: apnsEnvironment
            )
            try? await services.secrets.storeDeviceIdentity(
                .init(deviceID: response.deviceId, deviceKey: deviceKey),
                for: pairingID
            )

            let payload = QRPayload(
                pairingID: pairingID,
                rootSecret: rootSecret,
                apiBaseURL: apiBaseURL
            )
            // Listening starts before the code is on screen: a viewer can only
            // claim what it has scanned, but the socket must already be up when
            // it does, or the claim is announced to nobody.
            let link = PairingSignalingLink(
                identity: .init(
                    pairingID: pairingID,
                    apiBaseURL: apiBaseURL,
                    role: .camera,
                    deviceID: response.deviceId,
                    deviceKey: deviceKey,
                    signalingKey: keys.signaling
                ),
                factory: services.makeSignalingSocketFactory(),
                onPeerOnline: { [weak self] presence in
                    self?.handlePeerOnline(presence, pairingID: pairingID)
                }
            )
            candidates[pairingID] = Candidate(rootSecret: rootSecret, link: link, host: nil)
            link.start()

            qrURLString = payload.urlString()
            dispatch(machine.apply(.registered(pairingID: pairingID, at: Date())))
        } catch {
            let message = (error as? APIError)?.userFacingMessage
                ?? "Could not reach the CribWire server."
            errorMessage = message
            dispatch(machine.apply(.registrationFailed(message: message)))
        }
    }

    /// Creates a pairing with no server involved.
    ///
    /// The same secret and the same QR, minus the round trip: there is nothing to
    /// register with, so the Camera mints its own device id and starts
    /// advertising. A Viewer dialling in over Bonjour is the claim.
    private func registerLocalPairing() async {
        let pairingID = UUID()
        guard let rootSecret = try? RootSecret.generate(),
              let deviceKey = try? DeviceKey.generate()
        else {
            let message = String(localized: "Could not start a local pairing.")
            errorMessage = message
            dispatch(machine.apply(.registrationFailed(message: message)))
            return
        }

        let keys = rootSecret.deriveKeys()
        let deviceID = UUID().uuidString.lowercased()
        try? await services.secrets.storeDeviceIdentity(
            .init(deviceID: deviceID, deviceKey: deviceKey),
            for: pairingID
        )

        let host = LocalPairingHost(
            pairingID: pairingID,
            keys: keys,
            deviceID: deviceID,
            deviceKey: deviceKey
        ) { [weak self] claim in
            // Connecting *is* the claim offline; there is no presence event.
            self?.handleViewerClaim(pairingID: pairingID, viewerDeviceID: claim.viewerDeviceID)
        }
        candidates[pairingID] = Candidate(rootSecret: rootSecret, link: nil, host: host)
        host.start()

        // No `api` in the payload — that absence is what tells the Viewer this is
        // a local pairing.
        qrURLString = QRPayload(
            pairingID: pairingID,
            rootSecret: rootSecret,
            apiBaseURL: nil
        ).urlString()
        dispatch(machine.apply(.registered(pairingID: pairingID, at: Date())))
    }

    private func persist(pairingID: UUID, viewerDeviceID: String) async {
        guard let rootSecret = candidates[pairingID]?.rootSecret else { return }
        // `nil` for a local pairing: the record carries no backend because the
        // pairing has none, now or later.
        guard isLocalOnly || apiBaseURL != nil else { return }
        let record = PairingRecord(
            id: pairingID,
            localRole: .camera,
            apiBaseURL: isLocalOnly ? nil : apiBaseURL,
            peerDeviceID: viewerDeviceID
        )
        try? await services.savePairing(record, rootSecret: rootSecret)
        discardAllSecrets()
    }

    private func discardAllSecrets() {
        for candidate in candidates.values {
            candidate.stop()
        }
        candidates.removeAll()
        qrURLString = nil
    }
}
