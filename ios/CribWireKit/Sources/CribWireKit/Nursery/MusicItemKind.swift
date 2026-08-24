import Foundation

/// What a chosen id refers to: a playlist, or an album.
///
/// Both services keep albums and playlists in separate catalogues with separate
/// lookups, and CribWire carries exactly one opaque id from the Viewer's tap to
/// the Camera's player. So the kind has to travel with the id — and travel
/// *further* than the summary that described it, because the same id comes back
/// out of the Camera's own history days later, long after the listing that named
/// it is gone.
///
/// Hence two representations of the same fact: a field on `PlaylistSummary` and
/// on `PlaylistRecents.Entry`, which is what the Viewer draws an icon from, and
/// a prefix on the id itself, which is what a provider reads when all it has is
/// the id.
public enum MusicItemKind: String, Codable, CaseIterable, Sendable {

    case playlist = "p"
    case album = "a"

    /// The prefix an album's id travels under. Chosen over a separate field in
    /// `MusicCommand` because the id is the one thing every path already carries
    /// intact — the wire, `UserDefaults`, and a Viewer built before albums
    /// existed all hand it back unchanged.
    static let albumPrefix = "album:"

    /// The id as it travels.
    public func wireID(for id: String) -> String {
        switch self {
        case .playlist: return id
        case .album: return Self.albumPrefix + id
        }
    }

    /// The kind and the service's own id, back out of a travelling id.
    ///
    /// An id with no prefix is a playlist, which is what every id written before
    /// this type existed is — so a history recorded by an older build keeps
    /// playing rather than becoming a lookup for an album that never existed.
    public static func read(_ wireID: String) -> (kind: MusicItemKind, id: String) {
        guard wireID.hasPrefix(albumPrefix) else { return (.playlist, wireID) }
        return (.album, String(wireID.dropFirst(albumPrefix.count)))
    }
}
