import Combine
import Foundation
import KidsCamKit
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
    /// Transient hint under the viewfinder ("that isn't a KidsCam code").
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

    private let services: AppServices
    private let apnsToken: String
    private let apnsEnvironment: API.APNSEnvironment

    init(
        services: AppServices,
        apnsToken: String = "",
        apnsEnvironment: API.APNSEnvironment = .sandbox
    ) {
        self.services = services
        self.apnsToken = apnsToken
        self.apnsEnvironment = apnsEnvironment
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
            configuration: .init(baseURL: apiBaseURL, pairingID: pairingID, role: .viewer),
            keys: keys,
            transport: services.makeTransport()
        )

        do {
            let response = try await client.claimPairing(
                apnsToken: apnsToken,
                apnsEnvironment: apnsEnvironment
            )
            claimedDeviceID = response.deviceId
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
        discardSecret()
    }

    private func discardSecret() {
        pendingSecret = nil
        pendingPayload = nil
        claimedDeviceID = nil
    }

    // MARK: - Messages

    private func failure(for error: Error) -> PairingFailure {
        switch error as? APIError {
        case .viewerLimitReached:
            return .viewerLimitReached
        case .pairingNotFound:
            return .expired
        case .http(_, let message):
            return .backend(message: message ?? "The server refused the pairing.")
        default:
            return .backend(message: "Could not reach the KidsCam server.")
        }
    }

    private func hint(for error: QRPayload.ParseError) -> String {
        switch error {
        case .notAPairingURL:
            return "That is not a KidsCam pairing code."
        case .unsupportedVersion:
            return "That code was made by a different version of KidsCam. Update both devices."
        case .invalidPairingID, .invalidRootSecret:
            return "That pairing code is damaged. Ask the Camera for a new one."
        case .invalidAPIBaseURL:
            return "That code points at an address KidsCam will not connect to."
        }
    }
}
