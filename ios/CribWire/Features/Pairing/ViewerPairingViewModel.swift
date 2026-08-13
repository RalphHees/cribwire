import Combine
import Foundation
import CribWireKit
import SwiftUI

/// Drives the Viewer's pairing flow: scan → derive keys → claim → compare SAS →
/// persist.
///
/// The scanned root secret is held in memory only. It reaches the Keychain at
/// exactly one moment: after the user has confirmed that both screens show the
/// same six digits.
@MainActor
final class ViewerPairingViewModel: ObservableObject {

    @Published private(set) var state: ViewerPairingStateMachine.State = .idle
    /// Transient hint under the viewfinder ("that isn't a CribWire code").
    @Published private(set) var scanHint: String?

    var sasCode: SASCode? {
        if case .confirmingSAS(let confirming) = state { return confirming.sasCode }
        return nil
    }

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    private var machine = ViewerPairingStateMachine()
    /// The scanned secret, held only until the pairing is confirmed or abandoned.
    private var pendingSecret: RootSecret?
    private var pendingPayload: QRPayload?
    private var claimedDeviceID: String?
    /// This device's own auth key, held until the user confirms the SAS.
    private var claimedDeviceKey: DeviceKey?
    /// The socket that tells the Camera this viewer claimed the pairing
    /// (`security.md` §3.3 step 2). Claiming over REST is invisible to the
    /// Camera on its own — connecting here is what makes it show the SAS — so it
    /// stays up for as long as the codes are being compared.
    private var link: PairingSignalingLink?

    private let services: AppServices
    /// Set by tests; otherwise the token is read from the notification
    /// coordinator when the claim is actually made, because APNs registration
    /// completes asynchronously and may well finish after this screen appears.
    private let overriddenAPNSToken: String?
    private let overriddenAPNSEnvironment: API.APNSEnvironment?

    /// Empty when this device has no token yet. It matters more here than on the
    /// Camera — a Viewer with no token receives no alerts — which is why the
    /// scan screen asks for notification permission before it gets this far.
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
        self.overriddenAPNSToken = apnsToken
        self.overriddenAPNSEnvironment = apnsEnvironment
    }

    // MARK: - Intent

    func start() {
        scanHint = nil
        dispatch(machine.apply(.startScanning))
    }

    func cancel() {
        dispatch(machine.apply(.cancel))
    }

    func confirmSAS() {
        dispatch(machine.apply(.userConfirmedSAS))
    }

    func rejectSAS() {
        dispatch(machine.apply(.userRejectedSAS))
    }

    /// Handles a decoded QR string. Called for every frame that decodes, so it
    /// must be cheap and idempotent.
    func handleScannedString(_ string: String) {
        guard isScanning else { return }

        do {
            let payload = try QRPayload.parse(string)
            pendingPayload = payload
            pendingSecret = payload.rootSecret
            scanHint = nil
            dispatch(
                machine.apply(
                    .scanned(pairingID: payload.pairingID, apiBaseURL: payload.apiBaseURL)
                )
            )
        } catch let error as QRPayload.ParseError {
            scanHint = hint(for: error)
            dispatch(machine.apply(.scanRejected(error)))
        } catch {
            scanHint = "That code could not be read."
        }
    }

    // MARK: - Effects

    private func dispatch(_ effects: [ViewerPairingStateMachine.Effect]) {
        state = machine.state

        for effect in effects {
            switch effect {
            case .claimPairing(let pairingID, let apiBaseURL):
                Task { await self.claim(pairingID: pairingID, apiBaseURL: apiBaseURL) }
            case .stopScanning:
                break
            case .persistPairing(let pairingID):
                Task { await self.persist(pairingID: pairingID) }
            case .discardScannedSecret:
                discardSecret()
            }
        }
    }

    private func claim(pairingID: UUID, apiBaseURL: URL) async {
        guard let secret = pendingSecret else {
            dispatch(machine.apply(.claimFailed(.backend(message: "The scanned code was lost."))))
            return
        }

        let keys = secret.deriveKeys()
        let client = APIClient(
            configuration: .init(baseURL: apiBaseURL, pairingID: pairingID),
            keys: keys,
            transport: services.makeTransport()
        )

        do {
            // Protocol 1.1: this viewer mints its own key and registers it during
            // the bootstrap claim. Everything afterwards is signed with it, so the
            // server can tell devices apart rather than trusting a claimed role.
            let deviceKey = try DeviceKey.generate()
            let response = try await client.claimPairing(
                deviceKey: deviceKey,
                apnsToken: apnsToken,
                apnsEnvironment: apnsEnvironment
            )
            claimedDeviceID = response.deviceId
            claimedDeviceKey = deviceKey

            // Announce the claim before showing the code, so both screens light
            // up together rather than the Camera trailing behind.
            link?.stop()
            let link = PairingSignalingLink(
                identity: .init(
                    pairingID: pairingID,
                    apiBaseURL: apiBaseURL,
                    role: .viewer,
                    deviceID: response.deviceId,
                    deviceKey: deviceKey,
                    signalingKey: keys.signaling
                ),
                factory: services.makeSignalingSocketFactory()
            )
            self.link = link
            link.start()

            // The SAS is derived here, on this device, from the scanned secret —
            // it is never received from the network.
            dispatch(machine.apply(.claimSucceeded(sasCode: keys.sasCode)))
        } catch {
            dispatch(machine.apply(.claimFailed(failure(for: error))))
        }
    }

    private func persist(pairingID: UUID) async {
        guard let secret = pendingSecret, let payload = pendingPayload else { return }
        let record = PairingRecord(
            id: pairingID,
            localRole: .viewer,
            apiBaseURL: payload.apiBaseURL,
            localDeviceID: claimedDeviceID,
            displayName: "Camera"
        )
        try? await services.savePairing(record, rootSecret: secret)
        // Only now, after the user confirmed both screens show the same digits,
        // does this device's identity reach the Keychain.
        if let deviceID = claimedDeviceID, let deviceKey = claimedDeviceKey {
            try? await services.secrets.storeDeviceIdentity(
                .init(deviceID: deviceID, deviceKey: deviceKey),
                for: pairingID
            )
        }
        discardSecret()
    }

    private func discardSecret() {
        link?.stop()
        link = nil
        pendingSecret = nil
        pendingPayload = nil
        claimedDeviceID = nil
        claimedDeviceKey = nil
    }

    // MARK: - Messages

    private func failure(for error: Error) -> PairingFailure {
        switch error as? APIError {
        case .viewerLimitReached:
            return .viewerLimitReached
        case .pairingNotFound:
            return .expired
        case .http(_, _, let message):
            return .backend(message: message ?? "The server refused the pairing.")
        default:
            return .backend(message: "Could not reach the CribWire server.")
        }
    }

    private func hint(for error: QRPayload.ParseError) -> String {
        switch error {
        case .notAPairingURL:
            return "That is not a CribWire pairing code."
        case .unsupportedVersion:
            return "That code was made by a different version of CribWire. Update both devices."
        case .invalidPairingID, .invalidRootSecret:
            return "That pairing code is damaged. Ask the Camera for a new one."
        case .invalidAPIBaseURL:
            return "That code points at an address CribWire will not connect to."
        }
    }
}
