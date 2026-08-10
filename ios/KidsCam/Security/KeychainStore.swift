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
/// An `actor` rather than a queue: the Keychain API is synchronous and not
/// thread-safe against our own read-modify-write sequences, and the project uses
/// Swift Concurrency throughout (no GCD).
actor KeychainStore {

    /// Which access group an item lives in.
    ///
    /// Splitting these is deliberate. The Notification Service Extension only
    /// ever needs `K_evt` (`security.md` §5), so only `K_evt` goes in the shared
    /// group; the root secret and the signaling key stay in the app's private
    /// group where the extension — a separate, less-audited binary — cannot
    /// reach them.
    enum Scope: Hashable {
        /// The app's own default access group. Not readable by the extension.
        case appPrivate
        /// The app-group access group, shared with the notification extension.
        case sharedWithExtension
    }

    enum KeychainError: Error, Equatable {
        case unexpectedStatus(Int32)
        case unavailableOnThisPlatform
    }

    /// `kSecAttrService` value; scopes all KidsCam items under one namespace.
    static let service = "nl.kidscam.pairing"

    private let appGroupIdentifier: String?

    /// - Parameter appGroupIdentifier: the app-group identifier used as the
    ///   Keychain access group for shared items. `nil` (unit tests, previews)
    ///   makes `.sharedWithExtension` behave like `.appPrivate`.
    init(appGroupIdentifier: String?) {
        self.appGroupIdentifier = appGroupIdentifier
    }

    // MARK: - CRUD

    /// Writes (or replaces) an item. Never logs `value` or `account`.
    func set(_ value: Data, account: String, scope: Scope) throws {
        #if canImport(Security)
        var attributes = baseQuery(account: account, scope: scope)
        attributes[kSecValueData as String] = value
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        // Delete-then-add rather than SecItemUpdate: it is one code path, and it
        // guarantees the accessibility and synchronizable attributes of the
        // stored item are ours and not inherited from an older write.
        SecItemDelete(baseQuery(account: account, scope: scope) as CFDictionary)

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(Int32(status))
        }
        #else
        throw KeychainError.unavailableOnThisPlatform
        #endif
    }

    /// Reads an item, or `nil` when it is absent.
    func get(account: String, scope: Scope) throws -> Data? {
        #if canImport(Security)
        var query = baseQuery(account: account, scope: scope)
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
    func remove(account: String, scope: Scope) throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery(account: account, scope: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(Int32(status))
        }
        #else
        throw KeychainError.unavailableOnThisPlatform
        #endif
    }

    /// Removes every KidsCam item in a scope.
    ///
    /// Used for wipe-on-unpair and for the first-launch cleanup: Keychain items
    /// survive app deletion, so a reinstall must not silently inherit the keys of
    /// a pairing the user thinks is gone (`security.md` §6).
    func removeAll(scope: Scope) throws {
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrSynchronizable as String: false
        ]
        if let accessGroup = accessGroup(for: scope) {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(Int32(status))
        }
        #else
        throw KeychainError.unavailableOnThisPlatform
        #endif
    }

    /// Removes every KidsCam item in both scopes.
    func removeEverything() throws {
        try removeAll(scope: .appPrivate)
        try removeAll(scope: .sharedWithExtension)
    }

    // MARK: - Query building

    #if canImport(Security)
    private func baseQuery(account: String, scope: Scope) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            // Never sync to iCloud Keychain (security.md §3.2).
            kSecAttrSynchronizable as String: false
        ]
        if let accessGroup = accessGroup(for: scope) {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
    #endif

    private func accessGroup(for scope: Scope) -> String? {
        switch scope {
        case .appPrivate:
            // No explicit group: the item lands in the app's own default access
            // group, which the extension cannot read.
            return nil
        case .sharedWithExtension:
            return appGroupIdentifier
        }
    }
}
