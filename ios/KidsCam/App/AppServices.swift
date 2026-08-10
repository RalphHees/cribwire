import Combine
import Foundation
import KidsCamKit

/// The object graph. Built once at launch and handed down through the
/// environment, so every screen gets the same stores and tests can substitute
/// them wholesale.
@MainActor
final class AppServices: ObservableObject {

    let configuration: AppConfiguration
    let keychain: KeychainStore
    let secrets: PairingSecretsStore
    let registry: PairingRegistry
    /// Overridable so tests can drive the network without URLSession.
    let makeTransport: @Sendable () -> any HTTPTransport

    /// The device's role. Not a secret, so `UserDefaults` is fine — and nothing
    /// else in this app is allowed in there.
    @Published var role: PairingRole? {
        didSet { defaults.set(role?.rawValue, forKey: Self.roleKey) }
    }

    @Published private(set) var pairings: [PairingRecord] = []

    private let defaults: UserDefaults
    private static let roleKey = "kidscam.role"
    private static let hasLaunchedKey = "kidscam.hasLaunchedBefore"

    init(
        configuration: AppConfiguration = .current,
        defaults: UserDefaults = .standard,
        keychain: KeychainStore? = nil,
        registry: PairingRegistry? = nil,
        makeTransport: (@Sendable () -> any HTTPTransport)? = nil
    ) {
        self.configuration = configuration
        self.defaults = defaults

        let keychainStore = keychain
            ?? KeychainStore(appGroupIdentifier: configuration.keychainAccessGroup)
        self.keychain = keychainStore
        self.secrets = PairingSecretsStore(keychain: keychainStore)

        // A registry that cannot be created is not a reason to refuse to launch;
        // an in-memory-ish fallback in the temporary directory keeps the app
        // usable and the failure visible in the pairings list.
        self.registry = registry
            ?? ((try? PairingRegistry.makeDefault())
                ?? PairingRegistry(
                    fileURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("kidscam-pairings.json")
                ))

        self.makeTransport = makeTransport ?? { URLSessionTransport() }

        self.role = defaults.string(forKey: Self.roleKey).flatMap(PairingRole.init(rawValue:))
    }

    // MARK: - Launch

    /// First-launch cleanup (`security.md` §6).
    ///
    /// Keychain items survive app deletion but `UserDefaults` does not, so an
    /// absent launch marker means "fresh install" — and any Keychain item still
    /// present belongs to a pairing the user believes is gone. Wipe it before
    /// anything can read it.
    func performLaunchTasks() async {
        if !defaults.bool(forKey: Self.hasLaunchedKey) {
            try? await secrets.wipeEverything()
            try? await registry.removeAll()
            defaults.set(true, forKey: Self.hasLaunchedKey)
        }
        await reloadPairings()
    }

    func reloadPairings() async {
        pairings = (try? await registry.all()) ?? []
    }

    // MARK: - Pairing lifecycle

    func savePairing(_ record: PairingRecord, rootSecret: RootSecret) async throws {
        try await secrets.store(rootSecret: rootSecret, for: record.id)
        try await registry.upsert(record)
        await reloadPairings()
    }

    func updatePairing(_ record: PairingRecord) async {
        try? await registry.upsert(record)
        await reloadPairings()
    }

    /// Local half of revocation: forget the pairing and destroy its keys.
    /// The caller is responsible for the `DELETE` that revokes it server-side.
    func forgetPairing(_ pairingID: UUID) async {
        try? await secrets.wipe(pairingID: pairingID)
        try? await registry.remove(pairingID: pairingID)
        await reloadPairings()
    }

    // MARK: - API access

    /// Builds a client for a stored pairing, loading `K_auth` from the Keychain.
    func makeAPIClient(for record: PairingRecord) async throws -> APIClient? {
        guard let keys = try await secrets.loadKeys(for: record.id) else { return nil }
        return APIClient(
            configuration: .init(
                baseURL: record.apiBaseURL,
                pairingID: record.id,
                role: record.localRole
            ),
            keys: keys,
            transport: makeTransport()
        )
    }
}
