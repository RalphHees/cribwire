import Foundation

/// CribWire's own record of what has actually been played in the nursery.
///
/// Kept separately from whatever Apple Music or TIDAL considers "recently played",
/// because those are account-wide and include the commute, the kitchen and
/// everything else. The list that belongs on a baby monitor is the one built from
/// this Camera, at night, by this family.
///
/// Ordinary preferences rather than a secret — no key material, no token — so the
/// app stores it in `UserDefaults`. It is still the user's listening history, so
/// it never leaves the Camera except sealed, to a paired Viewer.
public struct PlaylistRecents: Codable, Equatable, Sendable {

    /// How many are kept. Deliberately smaller than `PlaylistShortlist.limit`, so
    /// the shortlist always has room for favourites underneath the history rather
    /// than being entirely consumed by it.
    public static let capacity = 8

    public struct Entry: Codable, Equatable, Sendable {
        public var playlistID: String
        public var provider: MusicProviderKind
        public var name: String
        public var playedAt: Date

        public init(
            playlistID: String,
            provider: MusicProviderKind,
            name: String,
            playedAt: Date
        ) {
            self.playlistID = playlistID
            self.provider = provider
            self.name = PlaylistSummary.truncate(name, to: PlaylistSummary.maxNameLength)
            self.playedAt = playedAt
        }

        var id: String { "\(provider.rawValue):\(playlistID)" }
    }

    /// Most recently played first.
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = Self.normalise(entries)
    }

    /// Records a play, moving an existing entry to the front rather than
    /// duplicating it.
    public mutating func record(
        playlistID: String,
        provider: MusicProviderKind,
        name: String,
        at date: Date
    ) {
        let entry = Entry(
            playlistID: playlistID,
            provider: provider,
            name: name,
            playedAt: date
        )
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(Self.capacity))
    }

    /// Drops a playlist that no longer exists on the provider, so a deleted
    /// playlist stops being offered.
    public mutating func forget(playlistID: String, provider: MusicProviderKind) {
        entries.removeAll { $0.playlistID == playlistID && $0.provider == provider }
    }

    /// The history as shortlist entries, ready for `PlaylistShortlist.build`.
    ///
    /// - Parameter providers: which services the Camera can currently play from.
    ///   History for a provider the user has since signed out of is skipped:
    ///   offering a TIDAL playlist on a Camera that can no longer play it is worse
    ///   than offering nothing.
    public func summaries(limitedTo providers: Set<MusicProviderKind>) -> [PlaylistSummary] {
        entries
            .filter { providers.contains($0.provider) }
            .map {
                PlaylistSummary(
                    playlistID: $0.playlistID,
                    provider: $0.provider,
                    name: $0.name,
                    lastPlayedAt: $0.playedAt
                )
            }
    }

    /// Newest first, deduplicated, capped. Applied on decode too, so a file
    /// written by a build with a different capacity — or hand-edited — cannot
    /// produce a list this type's own invariants say is impossible.
    private static func normalise(_ entries: [Entry]) -> [Entry] {
        var seen: Set<String> = []
        return entries
            .sorted { $0.playedAt > $1.playedAt }
            .filter { seen.insert($0.id).inserted }
            .prefix(capacity)
            .map { $0 }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = (try? container.decode([LenientEntry].self, forKey: .entries)) ?? []
        self.entries = Self.normalise(decoded.compactMap(\.entry))
    }

    /// Lets one unreadable entry fall out of the list instead of taking the whole
    /// history with it. A file written by a build that knows a provider this one
    /// does not would otherwise decode as empty, silently wiping every recent
    /// playlist the moment the user downgrades.
    private struct LenientEntry: Decodable {
        let entry: Entry?

        init(from decoder: Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }
}
