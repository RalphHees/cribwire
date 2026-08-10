import CryptoKit
import Foundation
import KidsCamKit

/// Stores and retrieves a pairing's keys, deciding which Keychain scope each key
/// belongs in.
///
/// The split matters: the Notification Service Extension gets `K_evt` and nothing
/// else, so a bug in the extension cannot expose the root secret or the signaling
/// key (`security.md` §5).
actor PairingSecretsStore {

    /// One key of one pairing. The raw values are Keychain account names, so
    /// they are part of the on-device storage format — do not rename casually.
    enum Item: String, CaseIterable {
        case rootSecret = "S"
        case auth = "k_auth"
        case signaling = "k_sig"
        case event = "k_evt"
        case sas = "k_sas"

        var scope: KeychainStore.Scope {
            switch self {
            case .event:
                // The only key the notification extension may read.
                return .sharedWithExtension
            case .rootSecret, .auth, .signaling, .sas:
                return .appPrivate
            }
        }
    }

    private let keychain: KeychainStore

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    // MARK: - Storage

    /// Persists the root secret and all four derived keys for `pairingID`.
    ///
    /// Called only after the user has confirmed the SAS: an unconfirmed pairing
    /// must leave nothing behind.
    func store(rootSecret: RootSecret, for pairingID: UUID) async throws {
        let keys = rootSecret.deriveKeys()

        try await write(rootSecret.rawBytesForKeychainStorage, .rootSecret, pairingID)
        try await write(keys.auth.kc_bytes, .auth, pairingID)
        try await write(keys.signaling.kc_bytes, .signaling, pairingID)
        try await write(keys.event.kc_bytes, .event, pairingID)
        try await write(keys.sas.kc_bytes, .sas, pairingID)
    }

    /// Reloads a pairing's keys after a restart. Returns `nil` if the pairing is
    /// not (or no longer) on this device.
    func loadKeys(for pairingID: UUID) async throws -> PairingKeys? {
        guard
            let auth = try await read(.auth, pairingID),
            let signaling = try await read(.signaling, pairingID),
            let event = try await read(.event, pairingID),
            let sas = try await read(.sas, pairingID)
        else {
            return nil
        }
        return PairingKeys(
            auth: SymmetricKey(data: auth),
            signaling: SymmetricKey(data: signaling),
            event: SymmetricKey(data: event),
            sas: SymmetricKey(data: sas)
        )
    }

    /// Wipe-on-unpair: removes every key of one pairing from both scopes.
    ///
    /// Revocation is only complete once this has run — the peer still holds its
    /// copy, so the local keys are useless and must not linger
    /// (`security.md` §6).
    func wipe(pairingID: UUID) async throws {
        for item in Item.allCases {
            try await keychain.remove(account: account(item, pairingID), scope: item.scope)
        }
    }

    /// First-launch cleanup. Keychain items outlive app deletion, so a fresh
    /// install starts by discarding anything an earlier install left behind.
    func wipeEverything() async throws {
        try await keychain.removeEverything()
    }

    // MARK: - Plumbing

    private func account(_ item: Item, _ pairingID: UUID) -> String {
        "\(pairingID.uuidString.lowercased()).\(item.rawValue)"
    }

    private func write(_ data: Data, _ item: Item, _ pairingID: UUID) async throws {
        try await keychain.set(data, account: account(item, pairingID), scope: item.scope)
    }

    private func read(_ item: Item, _ pairingID: UUID) async throws -> Data? {
        try await keychain.get(account: account(item, pairingID), scope: item.scope)
    }
}

// MARK: -

private extension SymmetricKey {
    /// Raw key bytes, for the one legitimate destination: the Keychain.
    var kc_bytes: Data {
        withUnsafeBytes { Data($0) }
    }
}
