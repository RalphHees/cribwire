import Foundation

#if canImport(Security)
import Security
#endif

/// Thin, typed wrapper over the iOS Keychain.
///
/// Every item this type writes is a generic password with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
/// `kSecAttrSynchronizable = false`, which is what `security.md` §3.2 requires:
/// keys are unreadable while the device is locked, never sync to iCloud Keychain,
/// and never travel in an encrypted device backup.
///
/// There is no access group. Items land in the app's own default group, which is
/// the tightest option available now that the app is the only binary in the
/// bundle — the split into an app-private and an app-group scope existed solely
/// so a Notification Service Extension could read `K_evt` out of a second
/// process, and that extension is gone (`security.md` §5).
///
/// An `actor` rather than a queue: the Keychain API is synchronous and not
/// thread-safe against our own read-modify-write sequences, and the project uses
/// Swift Concurrency throughout (no GCD).
actor KeychainStore {

    enum KeychainError: Error, Equatable {
        case unexpectedStatus(Int32)
        case unavailableOnThisPlatform
    }

    /// `kSecAttrService` value; scopes all CribWire items under one namespace.
    static let service = "nl.cribwire.pairing"

    /// The `kSecAttrAccount` naming scheme, in one place because it is an
    /// on-device storage format: a rename silently orphans every stored key of
    /// every existing pairing, and nothing fails loudly.
    static func account(pairingID: UUID, item: String) -> String {
        "\(pairingID.uuidString.lowercased()).\(item)"
    }

    init() {}

    // MARK: - CRUD

    /// Writes (or replaces) an item. Never logs `value` or `account`.
    func set(_ value: Data, account: String) throws {
        #if canImport(Security)
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = value
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        // Delete-then-add rather than SecItemUpdate: it is one code path, and it
        // guarantees the accessibility and synchronizable attributes of the
        // stored item are ours and not inherited from an older write.
        SecItemDelete(baseQuery(account: account) as CFDictionary)

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(Int32(status))
        }
        #else
        throw KeychainError.unavailableOnThisPlatform
        #endif
    }

    /// Reads an item, or `nil` when it is absent.
    func get(account: String) throws -> Data? {
        #if canImport(Security)
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(Int32(status))
        }
        #else
        throw KeychainError.unavailableOnThisPlatform
        #endif
    }

    /// Deletes an item. Deleting something that is not there is a success.
    func remove(account: String) throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(Int32(status))
        }
        #else
        throw KeychainError.unavailableOnThisPlatform
        #endif
    }

    /// Removes every CribWire item.
    ///
    /// Used for wipe-on-unpair and for the first-launch cleanup: Keychain items
    /// survive app deletion, so a reinstall must not silently inherit the keys of
    /// a pairing the user thinks is gone (`security.md` §6).
    func removeAll() throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrSynchronizable as String: false
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(Int32(status))
        }
        #else
        throw KeychainError.unavailableOnThisPlatform
        #endif
    }

    // MARK: - Query building

    #if canImport(Security)
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            // Never sync to iCloud Keychain (security.md §3.2).
            kSecAttrSynchronizable as String: false
        ]
    }
    #endif
}
