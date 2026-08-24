import CribWireKit
import Foundation

/// Where the Camera keeps the playlists it has actually played.
///
/// The same shape as `DetectionSettingsStore`, and for the same reason: these are
/// preferences, not secrets — no token, no key material — so `UserDefaults` is the
/// right home and the Keychain is not.
///
/// It is still the family's listening history, and it is the reason the Viewer's
/// list is short and correct rather than long and generic. It never leaves the
/// Camera except sealed under `K_sig`, to a paired Viewer.
struct MusicRecentsStore {

    static let key = "cribwire.musicRecents"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// An unreadable file yields an empty history rather than a failure. Losing
    /// the shortlist is a small inconvenience; refusing to play music because a
    /// preferences blob did not parse is not a trade worth making.
    func load() -> PlaylistRecents {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(PlaylistRecents.self, from: data)
        else {
            return PlaylistRecents()
        }
        return decoded
    }

    func save(_ recents: PlaylistRecents) {
        guard let data = try? JSONEncoder().encode(recents) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Records a play and returns the updated history.
    @discardableResult
    func record(
        playlistID: String,
        provider: MusicProviderKind,
        kind: MusicItemKind = .playlist,
        name: String,
        at date: Date = Date()
    ) -> PlaylistRecents {
        var recents = load()
        recents.record(
            playlistID: playlistID,
            provider: provider,
            kind: kind,
            name: name,
            at: date
        )
        save(recents)
        return recents
    }
}
