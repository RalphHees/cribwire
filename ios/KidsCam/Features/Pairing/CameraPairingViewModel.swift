import Foundation
import KidsCamKit
import SwiftUI

/// Drives the Camera's pairing screen: generate a secret, register it, render the
/// QR, rotate it every two minutes, and hand over to the SAS screen when a viewer
/// claims it.
///
/// All decisions live in `CameraPairingStateMachine`; this type only performs the
/// effects the machine asks for. That keeps the timing and expiry rules
/// unit-tested and keeps this file free of branching logic.
@MainActor
final class CameraPairingViewModel: ObservableObject {

    @Published private(set) var state: CameraPairingStateMachine.State = .idle
    /// The URL currently encoded in the QR. Held only while it is on screen.
    @Published private(set) var qrURLString: String?
    /// Seconds until the code is replaced.
    @Published private(set) var secondsUntilRegeneration: Int = 0
    @Published private(set) var errorMessage: String?

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
    /// Root secrets for pairings that are still claimable. Cleared aggressively:
    /// a secret that is no longer claimable is a liability.
    private var secretsByPairing: [UUID: RootSecret] = [:]
    private var tickTask: Task<Void, Never>?

    private let services: AppServices
    private let apiBaseURL: URL?
    /// APNs token for this device. Registration is a Phase 3 task; until then a
    /// placeholder is registered so the backend contract is exercised.
    private let apnsToken: String
    private let apnsEnvironment: API.APNSEnvironment

    init(
        services: AppServices,
        apnsToken: String = "",
        apnsEnvironment: API.APNSEnvironment = .sandbox
    ) {
        self.services = services
        self.apiBaseURL = services.configuration.defaultAPIBaseURL
        self.apnsToken = apnsToken
        self.apnsEnvironment = apnsEnvironment
    }

    deinit {
        tickTask?.cancel()
    }

    // MARK: - Lifecycle

    func start() {
        guard apiBaseURL != nil else {
            errorMessage = "No backend is configured in this build."
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

    /// Test/preview seam: normally driven by the backend WebSocket
    /// (`security.md` §3.3 step 2), which is Phase 2 work.
    func handleViewerClaim(pairingID: UUID, viewerDeviceID: String) {
        guard let secret = secretsByPairing[pairingID] else { return }
        dispatch(
            machine.apply(
                .viewerClaimed(
                    pairingID: pairingID,
                    viewerDeviceID: viewerDeviceID,
                    sasCode: secret.deriveKeys().sasCode
                )
            )
        )
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
                    secretsByPairing.removeValue(forKey: pairingID)
                }

            case .persistPairing(let pairingID, let viewerDeviceID):
                Task { await self.persist(pairingID: pairingID, viewerDeviceID: viewerDeviceID) }
            }
        }
    }

    private func registerNewPairing() async {
        guard let apiBaseURL else { return }

        do {
            // Fresh id *and* fresh secret for every attempt (security.md §3.1).
            let pairingID = UUID()
            let rootSecret = try RootSecret.generate()
            let keys = rootSecret.deriveKeys()

            let client = APIClient(
                configuration: .init(baseURL: apiBaseURL, pairingID: pairingID, role: .camera),
                keys: keys,
                transport: services.makeTransport()
            )
            _ = try await client.createPairing(
                apnsToken: apnsToken,
                apnsEnvironment: apnsEnvironment
            )

            let payload = QRPayload(
                pairingID: pairingID,
                rootSecret: rootSecret,
                apiBaseURL: apiBaseURL
            )
            secretsByPairing[pairingID] = rootSecret
            qrURLString = payload.urlString()
            dispatch(machine.apply(.registered(pairingID: pairingID, at: Date())))
        } catch {
            let message = (error as? APIError)?.userFacingMessage
                ?? "Could not reach the KidsCam server."
            errorMessage = message
            dispatch(machine.apply(.registrationFailed(message: message)))
        }
    }

    private func persist(pairingID: UUID, viewerDeviceID: String) async {
        guard let rootSecret = secretsByPairing[pairingID], let apiBaseURL else { return }
        let record = PairingRecord(
            id: pairingID,
            localRole: .camera,
            apiBaseURL: apiBaseURL,
            peerDeviceID: viewerDeviceID
        )
        try? await services.savePairing(record, rootSecret: rootSecret)
        discardAllSecrets()
    }

    private func discardAllSecrets() {
        secretsByPairing.removeAll()
        qrURLString = nil
    }
}
