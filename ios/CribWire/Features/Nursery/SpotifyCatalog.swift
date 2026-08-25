import CribWireKit
import Foundation
import OSLog

/// The Spotify Web API, reduced to the four questions CribWire asks it.
///
/// A hand-written client over `URLSession` rather than a generated one: four
/// endpoints, each of which needs three fields out of a response with fifty, and
/// none of which is worth the weight TIDAL's generated OpenAPI client already
/// costs this app (see `TidalCatalog` for what that weight looks like).
///
/// **Everything here answers rather than throws.** A rate-limited, offline or
/// simply grumpy music service must degrade to "nothing to offer tonight" on the
/// Viewer's screen — the rule the whole `MusicProvider` protocol is built on. The
/// one exception is deliberate and narrow: `playlistName` distinguishes *gone*
/// from *could not ask*, because `NurseryController` deletes a parent's history
/// entry on the first and must not on the second.
enum SpotifyCatalog {

    static let log = Logger(subsystem: "com.ralphhees.cribwire", category: "spotify")

    private static let base = "https://api.spotify.com/v1"

    /// Whether this account can actually play.
    ///
    /// Spotify says so up front, which TIDAL does not: `product` is `premium`,
    /// `free` or `open`, and only the first can be driven by App Remote. So
    /// unlike TIDAL — where a missing subscription only surfaces once a
    /// thirty-second preview starts — the Camera can report `needsSubscription`
    /// before a parent ever taps play.
    static func isPremium(token: String) async -> Bool? {
        guard let profile: Profile = await get("/me", token: token) else { return nil }
        return profile.product == "premium"
    }

    /// The parent's own playlists.
    static func playlists(token: String, limit: Int) async -> [PlaylistSummary] {
        guard let page: Page<PlaylistObject> = await get(
            "/me/playlists?limit=\(min(limit, 50))",
            token: token
        ) else { return [] }

        return page.items.compactMap { playlist in
            // A playlist with no id is not a playlist anyone can be sent back to
            // play, so it is dropped rather than shown as a row that does
            // nothing.
            guard let id = playlist.id, let name = playlist.name else { return nil }
            return PlaylistSummary(
                playlistID: MusicItemKind.playlist.wireID(for: id),
                provider: .spotify,
                kind: .playlist,
                name: name,
                detail: playlist.tracks.map { trackCountDetail($0.total) },
                isFavorite: true
            )
        }
    }

    /// The parent's saved albums.
    static func albums(token: String, limit: Int) async -> [PlaylistSummary] {
        guard let page: Page<SavedAlbum> = await get(
            "/me/albums?limit=\(min(limit, 50))",
            token: token
        ) else { return [] }

        return page.items.compactMap { saved in
            guard let id = saved.album.id, let name = saved.album.name else { return nil }
            return PlaylistSummary(
                // The `album:` prefix is what tells the provider which Spotify
                // URI to build when this id comes back out of the parent's
                // history months later, long after this listing is gone.
                playlistID: MusicItemKind.album.wireID(for: id),
                provider: .spotify,
                kind: .album,
                name: name,
                detail: saved.album.artists?.first?.name,
                isFavorite: true
            )
        }
    }

    /// What a playlist or album is called, and whether it is still there.
    ///
    /// The three answers exist because `NurseryController` acts on the middle one
    /// by editing the parent's history. A 404 is Spotify saying the thing is
    /// gone; anything else — a timeout, a 429, an expired token — is this Camera
    /// failing to ask, and a Camera failing to ask is not evidence about a
    /// playlist.
    static func name(
        for id: String,
        kind: MusicItemKind,
        token: String
    ) async -> NameLookup {
        let path = kind == .album ? "/albums/\(id)" : "/playlists/\(id)"
        // `fields` is honoured on playlists only; albums ignore it harmlessly.
        let result: Result<NamedObject, LookupFailure> = await fetch(
            "\(path)?fields=name",
            token: token
        )
        switch result {
        case .success(let object):
            guard let name = object.name else { return .unknown }
            return .named(name)
        case .failure(.notFound):
            return .gone
        case .failure(.other):
            return .unknown
        }
    }

    enum NameLookup: Equatable {
        case named(String)
        /// Spotify answered, and it is not there.
        case gone
        /// It could not be asked. Says nothing about whether it exists.
        case unknown
    }

    /// `12 songs`, or `1 song`. The second line of a row in a dark room, so it
    /// is the one fact worth having: how long this will last.
    private static func trackCountDetail(_ total: Int) -> String {
        total == 1
            ? String(localized: "1 song")
            : String(localized: "\(total) songs")
    }

    // MARK: - Transport

    private enum LookupFailure: Error {
        case notFound
        case other
    }

    private static func get<T: Decodable>(_ path: String, token: String) async -> T? {
        switch await fetch(path, token: token) as Result<T, LookupFailure> {
        case .success(let value): return value
        case .failure: return nil
        }
    }

    private static func fetch<T: Decodable>(
        _ path: String,
        token: String
    ) async -> Result<T, LookupFailure> {
        guard let url = URL(string: base + path) else { return .failure(.other) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Short, like the token request and for the same reason: a nursery phone
        // that has lost its uplink should find out in seconds rather than hold a
        // refresh tick behind the default minute.
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failure(.other) }

        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404 { return .failure(.notFound) }
            // Logged without the body: an error response can name the account.
            // The status is the part that is actionable and it is enough to tell
            // 401 (token) from 429 (asking too often) from 5xx (Spotify).
            log.error("Spotify \(path, privacy: .public) → \(http.statusCode, privacy: .public)")
            return .failure(.other)
        }

        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            return .failure(.other)
        }
        return .success(decoded)
    }

    // MARK: - Wire shapes

    /// Every field optional except the ones a row cannot exist without.
    ///
    /// Spotify's responses carry nulls in places its documentation does not
    /// mention — a playlist whose owner deleted their account, an album with no
    /// artist — and one of those must cost a single row, never the whole
    /// listing. Same reasoning as `TidalCatalog`'s salvage path, reached far
    /// more cheaply because these models are ours.
    private struct Page<Item: Decodable>: Decodable {
        let items: [Item]
    }

    private struct PlaylistObject: Decodable {
        let id: String?
        let name: String?
        let tracks: TrackCount?

        struct TrackCount: Decodable {
            let total: Int
        }
    }

    private struct SavedAlbum: Decodable {
        let album: AlbumObject
    }

    private struct AlbumObject: Decodable {
        let id: String?
        let name: String?
        let artists: [Artist]?

        struct Artist: Decodable {
            let name: String?
        }
    }

    private struct NamedObject: Decodable {
        let name: String?
    }

    private struct Profile: Decodable {
        let product: String?
    }
}
