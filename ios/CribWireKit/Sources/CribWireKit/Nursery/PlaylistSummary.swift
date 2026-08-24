import Foundation

/// One playlist, as the Viewer sees it.
///
/// Deliberately thin. The Viewer needs enough to recognise a playlist in a list at
/// 3 a.m. and to name it back to the Camera — nothing else. Artwork in particular
/// is *not* carried: the signaling channel has a 16 KiB frame cap, and a dozen
/// thumbnails would blow it many times over for something nobody squints at in the
/// dark.
public struct PlaylistSummary: Codable, Equatable, Identifiable, Sendable {

    /// Longest name put on the wire. A shortlist of `PlaylistShortlist.limit`
    /// entries at this length is a few kilobytes, which keeps the whole state
    /// message comfortably inside the signaling frame cap with no dynamic
    /// trimming anywhere.
    public static let maxNameLength = 60

    /// The provider's own identifier — opaque here, and handed straight back in
    /// `MusicCommand.selectPlaylist`.
    public var playlistID: String
    public var provider: MusicProviderKind
    /// Whether this is a playlist or an album. Read by the Viewer for the row's
    /// icon; the same fact is in `playlistID` for the Camera to route on.
    public var kind: MusicItemKind
    public var name: String
    /// Second line: track count, curator, whatever the provider offers.
    public var detail: String?
    /// In the user's library / marked as a favourite on the Camera.
    public var isFavorite: Bool
    /// When CribWire itself last started this playlist on the Camera. `nil` means
    /// it has never been played *from CribWire*, whatever the provider's own
    /// history says.
    public var lastPlayedAt: Date?

    /// Unique across providers, which the provider's own id is not.
    public var id: String { "\(provider.rawValue):\(playlistID)" }

    public init(
        playlistID: String,
        provider: MusicProviderKind,
        kind: MusicItemKind = .playlist,
        name: String,
        detail: String? = nil,
        isFavorite: Bool = false,
        lastPlayedAt: Date? = nil
    ) {
        self.playlistID = playlistID
        self.provider = provider
        self.kind = kind
        self.name = Self.truncate(name, to: Self.maxNameLength)
        self.detail = detail.map { Self.truncate($0, to: Self.maxNameLength) }
        self.isFavorite = isFavorite
        self.lastPlayedAt = lastPlayedAt
    }

    /// Truncates on a character boundary and marks the cut, so a shortened name
    /// never looks like the real one.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    enum CodingKeys: String, CodingKey {
        case playlistID = "i"
        case provider = "p"
        case kind = "k"
        case name = "n"
        case detail = "d"
        case isFavorite = "f"
        case lastPlayedAt = "t"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.playlistID = try container.decode(String.self, forKey: .playlistID)
        self.provider = try container.decode(MusicProviderKind.self, forKey: .provider)
        // Absent from anything a build before albums wrote, and from any Viewer
        // that predates them: a missing kind is a playlist.
        self.kind = (try? container.decodeIfPresent(MusicItemKind.self, forKey: .kind)) ?? .playlist
        self.name = Self.truncate(
            try container.decode(String.self, forKey: .name),
            to: Self.maxNameLength
        )
        self.detail = try? container.decodeIfPresent(String.self, forKey: .detail)
        self.isFavorite = (try? container.decodeIfPresent(Bool.self, forKey: .isFavorite)) ?? false
        self.lastPlayedAt = try? container.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
    }
}

// MARK: - Shortlist

/// Builds the short list of playlists the Viewer is offered.
///
/// The requirement it exists to satisfy is "only recently used ones or
/// favourites", and the ordering is the whole point of it. A parent reaching for
/// the phone in a dark room wants the thing they played last night at the top; a
/// full library is not a menu, it is a search problem, and it does not belong on a
/// screen used one-handed while holding a baby.
///
/// Three sources, in descending order of how likely the entry is to be the one
/// being reached for:
///
/// 1. **What CribWire itself has played on this Camera**, most recent first. This
///    is the strongest signal by far — it is literally the nursery's own history,
///    not the account's.
/// 2. **The provider's recently played**, which covers a playlist started on
///    another device but obviously in rotation.
/// 3. **Favourites / library playlists**, as the standing set.
///
/// Duplicates are merged rather than dropped: a playlist that is both a favourite
/// and the last one played keeps its star *and* its position at the top.
public enum PlaylistShortlist {

    /// How many entries the Viewer is offered, and the bound that keeps the
    /// state message inside the signaling frame cap.
    ///
    /// Still a shortlist rather than a library — see above — but a dozen was too
    /// short to be one: an ordinary TIDAL collection is several times that, so
    /// the cap was doing the same thing to the list that a failed read does,
    /// which is hide most of it. Thirty leaves the history and the favourites
    /// room to coexist and still fits the frame with the worst case of
    /// maximum-length names and details (`NurseryStateTests`).
    public static let limit = 30

    public static func build(
        cameraRecents: [PlaylistSummary],
        recentlyPlayed: [PlaylistSummary] = [],
        favorites: [PlaylistSummary] = [],
        limit: Int = limit
    ) -> [PlaylistSummary] {
        var ordered: [PlaylistSummary] = []
        var indexByID: [String: Int] = [:]

        for candidate in cameraRecents + recentlyPlayed + favorites {
            if let existing = indexByID[candidate.id] {
                ordered[existing] = merge(ordered[existing], with: candidate)
            } else {
                indexByID[candidate.id] = ordered.count
                ordered.append(candidate)
            }
        }

        return Array(ordered.prefix(max(limit, 0)))
    }

    /// Keeps the position of the earlier (higher-priority) entry and takes any
    /// fact the later one knows and it does not — including, in one narrow
    /// case, its name.
    private static func merge(
        _ kept: PlaylistSummary,
        with other: PlaylistSummary
    ) -> PlaylistSummary {
        var merged = kept
        // A history entry whose name is its own id — recorded on a night when
        // the name request was the one call that failed — must not outrank a
        // listing that knows what the playlist is called. Nothing else may
        // replace the kept name: the history's copy is the one the parent has
        // been reading at the top of the list.
        if kept.name == kept.playlistID, other.name != other.playlistID {
            merged.name = other.name
        }
        merged.isFavorite = kept.isFavorite || other.isFavorite
        merged.detail = kept.detail ?? other.detail
        switch (kept.lastPlayedAt, other.lastPlayedAt) {
        case (let mine?, let theirs?): merged.lastPlayedAt = max(mine, theirs)
        case (nil, let theirs?): merged.lastPlayedAt = theirs
        default: break
        }
        return merged
    }
}
