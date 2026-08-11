import CryptoKit
import Foundation
import KidsCamKit

/// Reads `K_evt` out of the **app-group** Keychain.
///
/// Compiled into both the app and the Notification Service Extension (see
/// `ios/project.yml`), which is the point: the two binaries must agree on the
/// service name, the account name and the access group, and the way to
/// guarantee that is to share the code rather than the convention.
///
/// This is the only key the extension can reach. The root secret, `K_sig` and
/// the device key live in the app's private access group, so a bug in the
/// extension — the smaller, less-exercised binary — cannot expose them
/// (`security.md` §5).
actor EventKeyStore {

    private let keychain: KeychainStore

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    init(appGroupIdentifier: String?) {
        self.init(keychain: KeychainStore(appGroupIdentifier: appGroupIdentifier))
    }

    /// - Returns: `K_evt` for the pairing, or `nil` when this device holds no
    ///   such pairing. Callers must treat `nil` and a decryption failure the
    ///   same way: show the generic alert, log nothing.
    func eventKey(for pairingID: UUID) async throws -> SymmetricKey? {
        let account = KeychainStore.account(
            pairingID: pairingID,
            item: KeychainStore.eventKeyItem
        )
        guard let data = try await keychain.get(account: account, scope: .sharedWithExtension),
              data.count == PairingKeys.keyByteCount
        else {
            return nil
        }
        return SymmetricKey(data: data)
    }
}
