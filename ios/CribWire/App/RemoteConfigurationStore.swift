import CribWireKit
import Foundation

/// The last `GET /v1/config` this device received.
///
/// Cached rather than fetched on demand for two reasons: the values change on
/// the order of months, and a Camera that cannot reach the backend must still
/// come up exactly as it did yesterday. A stale client id is worth far more
/// than none.
///
/// `UserDefaults`, like `MusicRecentsStore` and for the same reason: nothing in
/// here is a secret. The server refuses to serve anything that is — a client id
/// is public in every OAuth exchange — and this file is where that assumption
/// becomes visible, because anything written here is readable by anyone holding
/// the phone. If a value ever needs the Keychain, it does not belong in this
/// endpoint at all.
struct RemoteConfigurationStore {

    static let key = "cribwire.remoteConfiguration"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// An unreadable or absent blob is an empty configuration, never a failure:
    /// the app falls back to what it was built with.
    func load() -> RemoteConfiguration {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(RemoteConfiguration.self, from: data)
        else {
            return RemoteConfiguration()
        }
        return decoded
    }

    func save(_ configuration: RemoteConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Folds a fresh response into what is stored.
    func record(_ response: API.AppConfigurationResponse, at date: Date = Date()) {
        save(
            RemoteConfiguration(
                tidalClientID: response.tidal?.clientID,
                spotifyClientID: response.spotify?.clientID,
                fetchedAt: date,
                ttlSeconds: TimeInterval(response.ttlSeconds)
            )
        )
    }
}

/// What the backend said, and when.
struct RemoteConfiguration: Codable, Equatable {

    /// `nil` when the deployment serves no TIDAL id — which is not the same as
    /// an empty one, and is why this is optional rather than defaulted.
    var tidalClientID: String?
    /// The same, for Spotify. A deployment may serve either, both or neither,
    /// and each one decides on its own whether that service is offered at all.
    var spotifyClientID: String?
    var fetchedAt: Date?
    var ttlSeconds: TimeInterval?

    /// A day, when the server did not say. Long enough that a Camera left alone
    /// asks rarely, short enough that a rotation lands without anyone touching
    /// the phone.
    static let defaultTTL: TimeInterval = 24 * 60 * 60

    /// Whether it is worth asking again.
    ///
    /// A clock that has gone backwards — a manual date change, or a phone that
    /// booted before its first NTP sync — counts as stale rather than fresh for
    /// ever, which is the failure that would otherwise pin a Camera to an id
    /// that had been retired.
    func isStale(at now: Date = Date()) -> Bool {
        guard let fetchedAt else { return true }
        let age = now.timeIntervalSince(fetchedAt)
        if age < 0 { return true }
        return age >= (ttlSeconds ?? Self.defaultTTL)
    }
}
