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
        name: String,
        detail: String? = nil,
        isFavorite: Bool = false,
        lastPlayedAt: Date? = nil
    ) {
        self.playlistID = playlistID
        self.provider = provider
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
        case name = "n"
        case detail = "d"
        case isFavorite = "f"
        case lastPlayedAt = "t"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.playlistID = try container.decode(String.self, forKey: .playlistID)
        self.provider = try container.decode(MusicProviderKind.self, forKey: .provider)
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

    /// How many entries the Viewer is offered. Small on purpose — see above — and
    /// the bound that keeps the state message inside the signaling frame cap.
    public static let limit = 12

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

    /// Keeps the position and name of the earlier (higher-priority) entry, and
    /// takes any fact the later one knows and it does not.
    private static func merge(
        _ kept: PlaylistSummary,
        with other: PlaylistSummary
    ) -> PlaylistSummary {
        var merged = kept
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
