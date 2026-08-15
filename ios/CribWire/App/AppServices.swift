import Foundation
import CribWireKit

/// The object graph. Built once at launch and handed down through the
/// environment, so every screen gets the same stores and tests can substitute
/// them wholesale.
@MainActor
@Observable
final class AppServices {

    let configuration: AppConfiguration
    let keychain: KeychainStore
    let secrets: PairingSecretsStore
    let registry: PairingRegistry
    /// Permission, APNs registration and event-payload decryption — the job the
    /// Notification Service Extension used to do in its own process.
    let notifications: PushNotificationCoordinator
    /// Overridable so tests can drive the network without URLSession.
    let makeTransport: @Sendable () -> any HTTPTransport
    /// The same seam for WebSockets. Pairing needs one before any pairing exists
    /// (`security.md` §3.3 step 2), so it lives here rather than in the
    /// streaming engine that will also use it.
    let makeSignalingSocketFactory: @Sendable () -> any SignalingSocketFactory

    /// The device's role. Not a secret, so `UserDefaults` is fine — and nothing
    /// else in this app is allowed in there.
    ///
    /// Computed over `storedRole` rather than carrying a `didSet`, because the
    /// two cannot coexist: `@Observable` rewrites stored properties into
    /// get/set accessors, and Swift does not allow a property to have both
    /// accessors and observers. Observation is unaffected — every read and write
    /// passes through `storedRole`, which is the property SwiftUI tracks.
    var role: PairingRole? {
        get { storedRole }
        set {
            storedRole = newValue
            defaults.set(newValue?.rawValue, forKey: Self.roleKey)
        }
    }

    private var storedRole: PairingRole?

    private(set) var pairings: [PairingRecord] = []

    private let defaults: UserDefaults
    private static let roleKey = "cribwire.role"
    private static let hasLaunchedKey = "cribwire.hasLaunchedBefore"

    init(
        configuration: AppConfiguration = .current,
        defaults: UserDefaults = .standard,
        keychain: KeychainStore? = nil,
        registry: PairingRegistry? = nil,
        makeTransport: (@Sendable () -> any HTTPTransport)? = nil,
        makeSignalingSocketFactory: (@Sendable () -> any SignalingSocketFactory)? = nil
    ) {
        self.configuration = configuration
        self.defaults = defaults

        let keychainStore = keychain ?? KeychainStore()
        self.keychain = keychainStore
        let secretsStore = PairingSecretsStore(keychain: keychainStore)
        self.secrets = secretsStore
        self.notifications = PushNotificationCoordinator(secrets: secretsStore)

        // A registry that cannot be created is not a reason to refuse to launch;
        // an in-memory-ish fallback in the temporary directory keeps the app
        // usable and the failure visible in the pairings list.
        self.registry = registry
            ?? ((try? PairingRegistry.makeDefault())
                ?? PairingRegistry(
                    fileURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("cribwire-pairings.json")
                ))

        self.makeTransport = makeTransport ?? { URLSessionTransport() }
        self.makeSignalingSocketFactory = makeSignalingSocketFactory
            ?? { URLSessionSignalingSocketFactory() }

        // Straight to the backing store: going through `role` would write the
        // value it was just read from back into UserDefaults.
        self.storedRole = defaults.string(forKey: Self.roleKey)
            .flatMap(PairingRole.init(rawValue:))
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

    /// The Camera's alert settings. Read by the streaming engine, which must not
    /// stop capture while a detector is still consuming frames.
    var detectionSettings: DetectionSettings {
        DetectionSettingsStore(defaults: defaults).load()
    }

    /// How much light the Camera makes its picture from.
    ///
    /// Read-only here, like `detectionSettings`. Both are *written* by whoever
    /// owns the change — the alerts screen through its own store, and a Viewer's
    /// change through `NurseryController`, which has to persist and report it in
    /// one step. A second writer on this object would be a second place for the
    /// two to drift apart.
    var cameraSensitivity: CameraSensitivity {
        CameraSensitivityStore(defaults: defaults).load()
    }

    // MARK: - API access

    /// Builds a client for a stored pairing, loading `K_auth` from the Keychain.
    /// Client for an established pairing.
    ///
    /// Authenticates as **this device** (protocol 1.1), not with the pairing-wide
    /// `K_auth`: the bootstrap key only ever signs pairing-create and claim, and
    /// the server derives the role from the device row it authenticated. Returns
    /// `nil` if this device has no stored identity — that means pairing never
    /// completed, and there is nothing it is entitled to call.
    /// Refreshes the deployment configuration the backend can change between
    /// releases, if the cached copy has aged out.
    ///
    /// Deliberately silent about failure. Every value it fetches has a built-in
    /// fallback, so a Camera that cannot reach the backend behaves exactly as it
    /// did before — and a monitor is not a thing to hold up, or to report an
    /// error on, because a music service's client id could not be refreshed.
    func refreshRemoteConfiguration(for record: PairingRecord) async {
        let store = RemoteConfigurationStore(defaults: defaults)
        guard store.load().isStale() else { return }
        guard let client = (try? await makeAPIClient(for: record)) ?? nil,
              let response = try? await client.appConfiguration()
        else {
            return
        }
        store.record(response)
    }

    func makeAPIClient(for record: PairingRecord) async throws -> APIClient? {
        // A local-network pairing has no backend to call, by construction. Every
        // caller already treats `nil` as "nothing this pairing is entitled to
        // ask for", which is exactly right here too.
        guard let baseURL = record.apiBaseURL,
              let identity = try await secrets.loadDeviceIdentity(for: record.id)
        else {
            return nil
        }
        return APIClient(
            configuration: .init(baseURL: baseURL, pairingID: record.id),
            credentials: .device(deviceID: identity.deviceID, deviceKey: identity.deviceKey),
            transport: makeTransport()
        )
    }
}
