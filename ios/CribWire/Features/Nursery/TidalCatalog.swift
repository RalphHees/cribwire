import CribWireKit
import Foundation
import OSLog
import TidalAPI

/// One track, reduced to what a queue and a Viewer's screen actually need.
///
/// The artist is deliberately absent. The playlist-items endpoint returns track
/// titles but no artist names, and the only way to get them is a second request
/// per track — so `TidalMusicProvider` fills them in lazily for the one track
/// that is playing, rather than making a parent wait on metadata for a hundred
/// tracks nobody is listening to yet.
struct TidalTrack: Equatable, Sendable {
    let id: String
    /// `nil` until something resolves it. The id is what plays; the title is
    /// only ever read by the Viewer's "now playing" line, so a track with no
    /// title yet is still a track worth queueing — see `tracks(inPlaylist:)`.
    let title: String?
}

/// The reads CribWire makes against the TIDAL Open API.
///
/// Every function here answers with an empty or `nil` result rather than
/// throwing. That is the same rule the `MusicProvider` protocol states and it
/// matters more here than anywhere else in this feature: these are the calls
/// most likely to fail — a phone on a nursery shelf with two bars of Wi-Fi, a
/// token that expired while the app was in the background, an account whose
/// developer registration is missing a scope. None of that may reach the
/// signaling path, so all of it becomes "nothing to offer" and the Viewer sees
/// a service with no playlists instead of a monitor that stopped.
///
/// Authentication is entirely implicit: `TidalSession` points
/// `OpenAPIClientAPI.credentialsProvider` at `TidalAuth`, and the generated
/// `…APITidal` wrappers attach and refresh the bearer token themselves. Nothing
/// in this file ever sees a token, which is why nothing in this file has to be
/// careful with one.
enum TidalCatalog {

    /// Shared with `TidalMusicProvider` and `TidalSession`: one subsystem for
    /// the whole feature, because diagnosing "the room stayed silent" means
    /// reading the catalogue reads and the player's own reports together.
    static let log = Logger(subsystem: "com.ralphhees.cribwire", category: "tidal")

    /// How many pages of a relationship are ever walked.
    ///
    /// A ceiling rather than a target. TIDAL pages by cursor with no stated page
    /// size, so "read it all" is an unbounded number of round trips against a
    /// playlist somebody may have put ten thousand tracks in; the queue is
    /// capped anyway, and this is what stops the loop that fills it.
    private static let maxPages = 8

    // MARK: - Playlists

    /// One playlist, between the four shapes TIDAL hands it over in — a
    /// collection relationship, a filtered list, a single resource, and the
    /// lenient re-read of any of those — and the one shape the shortlist uses.
    ///
    /// The name is optional here and required in `PlaylistSummary`, which is the
    /// whole point of the type: an id can arrive without a name (the server
    /// declined the `include`, or its sideloaded copy would not decode), and
    /// that is a name to go and fetch rather than a playlist to drop.
    struct PlaylistEntry {
        let id: String
        let name: String?
        let detail: String?
    }

    /// One page of playlists and the cursor that follows it.
    struct EntryPage {
        let entries: [PlaylistEntry]
        let nextCursor: String?
    }

    /// How many ids are asked for in one `filter[id]` lookup. Small because the
    /// server's own limit is unstated and a 400 here would cost the names of a
    /// whole page.
    private static let idsPerLookup = 10

    /// The playlists in the user's collection — TIDAL's "My Collection", which
    /// is the closest thing it has to Apple Music's library, and includes
    /// playlists made by other people that the user saved.
    ///
    /// Two routes, tried in order, because the two need different scopes and a
    /// client registered at `developer.tidal.com` may hold only one of them:
    ///
    /// 1. the collection (`collection.read`) — what the user *saved*, which is
    ///    what a parent means by "my playlists";
    /// 2. the playlists they own (`playlists.read`) — narrower, but it is a
    ///    real answer where the first call comes back 403.
    ///
    /// Falling back rather than failing is the point: a build whose registration
    /// is missing one scope still offers something to play. The fall is also why
    /// the first route must not fail for cosmetic reasons — everything the user
    /// saved but did not make is in the collection and nowhere else, so a
    /// collection read that gives up quietly reads, on the Viewer, as most of
    /// the library having disappeared.
    static func collectionPlaylists(userID: String, limit: Int) async -> [PlaylistSummary] {
        let collection = await savedPlaylists(userID: userID, limit: limit)
        if !collection.isEmpty { return collection }
        log.notice("collection playlists came back empty for \(userID, privacy: .public); trying owned")
        return await ownedPlaylists(userID: userID, limit: limit)
    }

    private static func savedPlaylists(userID: String, limit: Int) async -> [PlaylistSummary] {
        var entries: [PlaylistEntry] = []
        var cursor: String?

        for page in 0 ..< maxPages {
            guard let read = await collectionPage(ofUser: userID, cursor: cursor, page: page)
            else { break }

            entries.append(contentsOf: read.entries)
            guard entries.count < limit, let next = read.nextCursor else { break }
            cursor = next
        }
        return await summaries(for: Array(entries.prefix(limit)), kind: .playlist)
    }

    /// One page of the collection's playlists relationship.
    ///
    /// Ordered by `data` and never by `included`: the relationship array is the
    /// collection's own order, while sideloaded resources are promised no order
    /// at all — and, since a missing name is looked up later, an id that did not
    /// arrive sideloaded is no longer a playlist lost. That mattered: this read
    /// used to keep only the ids it found in `included`, so a response the
    /// generated models would not decode, or an `include` the server declined,
    /// emptied the collection — and an empty collection falls through to the
    /// owned-playlists route, which knows nothing about anything the user saved
    /// rather than made.
    private static func collectionPage(
        ofUser userID: String,
        cursor: String?,
        page: Int
    ) async -> EntryPage? {
        do {
            let document = try await UserCollectionsAPITidal
                .userCollectionsIdRelationshipsPlaylistsGet(
                    id: userID,
                    pageCursor: cursor,
                    // Most recently saved first. The shortlist is a fraction of
                    // a real collection, so which end of it is read is the
                    // difference between offering the playlists a parent added
                    // for this baby and offering whatever they saved in 2016.
                    // What they actually play is covered from the other side,
                    // by the Camera's own history, which is merged in above it.
                    sort: [.PlaylistsAddedAtDesc],
                    include: ["playlists"]
                )
            let sideloaded = playlists(in: document.included)
            let entries = (document.data ?? []).map { identifier in
                PlaylistEntry(
                    id: identifier.id,
                    name: sideloaded[identifier.id]?.attributes?.name,
                    detail: sideloaded[identifier.id]?.attributes?.description
                )
            }
            return EntryPage(entries: entries, nextCursor: pageCursor(after: document.links.next))
        } catch {
            return salvagedEntryPage(
                from: error,
                describing: "collection playlists for \(userID) page \(page)"
            )
        }
    }

    private static func ownedPlaylists(userID: String, limit: Int) async -> [PlaylistSummary] {
        var entries: [PlaylistEntry] = []
        var cursor: String?

        for page in 0 ..< maxPages {
            guard let read = await ownedPage(ofUser: userID, cursor: cursor, page: page) else { break }

            entries.append(contentsOf: read.entries)
            guard entries.count < limit, let next = read.nextCursor else { break }
            cursor = next
        }
        return await summaries(for: Array(entries.prefix(limit)), kind: .playlist)
    }

    private static func ownedPage(
        ofUser userID: String,
        cursor: String?,
        page: Int
    ) async -> EntryPage? {
        do {
            let document = try await PlaylistsAPITidal.playlistsGet(
                pageCursor: cursor,
                // Same reasoning as the collection, with the field this route
                // offers: a playlist the parent edited recently is the one they
                // are still building.
                sort: [.LastModifiedAtDesc],
                filterOwnersId: [userID]
            )
            return EntryPage(
                entries: document.data.map(entry(for:)),
                nextCursor: pageCursor(after: document.links.next)
            )
        } catch {
            return salvagedEntryPage(
                from: error,
                describing: "owned playlists for \(userID) page \(page)"
            )
        }
    }

    /// Turns ids into the two lines the Viewer renders, fetching the names that
    /// did not come along for the ride.
    ///
    /// An entry that is still nameless after the lookup is dropped rather than
    /// labelled with its own UUID: a row a parent cannot recognise in the dark
    /// is not a row worth offering, and an id no `filter[id]` will name is one
    /// that would very likely not play either.
    private static func summaries(
        for entries: [PlaylistEntry],
        kind: MusicItemKind
    ) async -> [PlaylistSummary] {
        let unnamed = entries.filter { $0.name == nil }.map(\.id)
        let resolved = unnamed.isEmpty ? [:] : await names(of: unnamed, kind: kind)

        let summaries = entries.compactMap { entry -> PlaylistSummary? in
            guard let name = entry.name ?? resolved[entry.id]?.name else { return nil }
            return PlaylistSummary(
                // Prefixed for an album, so that the id alone tells the Camera
                // which catalogue to look in when a Viewer — or the Camera's own
                // history, weeks later — hands it back. See `MusicItemKind`.
                playlistID: kind.wireID(for: entry.id),
                provider: .tidal,
                kind: kind,
                name: name,
                // The playlist's own description, and nothing composed here. A
                // second line that says something the service said is worth
                // showing; one this app invented is just noise in two languages.
                detail: entry.detail ?? resolved[entry.id]?.detail,
                isFavorite: true
            )
        }
        if summaries.count < entries.count {
            log.notice(
                """
                dropped \(entries.count - summaries.count, privacy: .public) of \
                \(entries.count, privacy: .public) \(kind.rawValue, privacy: .public)                 entries that could not be named
                """
            )
        }
        return summaries
    }

    /// Names for ids the listing did not carry them for, a batch at a time.
    private static func names(
        of ids: [String],
        kind: MusicItemKind
    ) async -> [String: PlaylistEntry] {
        var found: [String: PlaylistEntry] = [:]

        for start in stride(from: 0, to: ids.count, by: idsPerLookup) {
            let batch = Array(ids[start ..< min(start + idsPerLookup, ids.count)])
            for entry in await lookup(ids: batch, kind: kind) where entry.name != nil {
                found[entry.id] = entry
            }
        }
        log.debug(
            """
            named \(found.count, privacy: .public) of \(ids.count, privacy: .public) \
            \(kind.rawValue, privacy: .public) entries the listing did not name
            """
        )
        return found
    }

    private static func lookup(ids: [String], kind: MusicItemKind) async -> [PlaylistEntry] {
        do {
            switch kind {
            case .playlist:
                return try await PlaylistsAPITidal.playlistsGet(filterId: ids).data.map(entry(for:))
            case .album:
                return try await AlbumsAPITidal.albumsGet(filterId: ids).data.map(entry(for:))
            }
        } catch {
            return salvagedEntryPage(
                from: error,
                describing: "\(kind.rawValue) lookup for \(ids.count) ids"
            )?.entries ?? []
        }
    }

    /// The playlist's display name, for the Camera's own recents list.
    ///
    /// Asked for separately rather than carried along from the shortlist,
    /// because the id a Viewer sends may have come from a recents entry that
    /// outlived the app launch it was recorded in — there is no in-memory
    /// playlist to read the name off. What it answers is what the parent then
    /// sees at the top of their list for as long as they keep playing it, so it
    /// is worth the salvage: a name that fails here is a UUID in the history.
    static func playlistName(id: String) async -> String? {
        do {
            return try await PlaylistsAPITidal.playlistsIdGet(id: id).data.attributes?.name
        } catch {
            return salvagedEntryPage(from: error, describing: "playlist name for \(id)")?
                .entries.first { $0.id == id }?.name
        }
    }

    private static func entry(for album: AlbumsResourceObject) -> PlaylistEntry {
        // `title`, where a playlist has `name` — the one place the two
        // catalogues disagree about what a thing is called.
        PlaylistEntry(id: album.id, name: album.attributes?.title, detail: nil)
    }

    private static func entry(for playlist: PlaylistsResourceObject) -> PlaylistEntry {
        PlaylistEntry(
            id: playlist.id,
            name: playlist.attributes?.name,
            detail: playlist.attributes?.description
        )
    }

    private static func playlists(in included: [IncludedInner]?) -> [String: PlaylistsResourceObject] {
        var byID: [String: PlaylistsResourceObject] = [:]
        for item in included ?? [] {
            guard case .playlistsResourceObject(let playlist) = item else { continue }
            byID[playlist.id] = playlist
        }
        return byID
    }

    // MARK: - Albums

    /// The albums in the user's collection — the ones they saved, newest first.
    ///
    /// One route rather than the playlists' two: an album has no owner to fall
    /// back to filtering by, so a collection read that fails here is simply no
    /// albums, and the playlists still fill the list.
    static func collectionAlbums(userID: String, limit: Int) async -> [PlaylistSummary] {
        var entries: [PlaylistEntry] = []
        var cursor: String?

        for page in 0 ..< maxPages {
            guard let read = await albumPage(ofUser: userID, cursor: cursor, page: page)
            else { break }

            entries.append(contentsOf: read.entries)
            guard entries.count < limit, let next = read.nextCursor else { break }
            cursor = next
        }
        return await summaries(for: Array(entries.prefix(limit)), kind: .album)
    }

    private static func albumPage(
        ofUser userID: String,
        cursor: String?,
        page: Int
    ) async -> EntryPage? {
        do {
            let document = try await UserCollectionsAPITidal
                .userCollectionsIdRelationshipsAlbumsGet(
                    id: userID,
                    pageCursor: cursor,
                    sort: [.AlbumsAddedAtDesc],
                    include: ["albums"]
                )
            let sideloaded = albums(in: document.included)
            let entries = (document.data ?? []).map { identifier in
                PlaylistEntry(
                    id: identifier.id,
                    name: sideloaded[identifier.id]?.attributes?.title,
                    detail: nil
                )
            }
            return EntryPage(entries: entries, nextCursor: pageCursor(after: document.links.next))
        } catch {
            return salvagedEntryPage(
                from: error,
                describing: "collection albums for \(userID) page \(page)"
            )
        }
    }

    /// The album's display title, for the Camera's own recents list. The
    /// counterpart of `playlistName(id:)`, and salvaged for the same reason.
    static func albumName(id: String) async -> String? {
        do {
            return try await AlbumsAPITidal.albumsIdGet(id: id).data.attributes?.title
        } catch {
            return salvagedEntryPage(from: error, describing: "album name for \(id)")?
                .entries.first { $0.id == id }?.name
        }
    }

    private static func albums(in included: [IncludedInner]?) -> [String: AlbumsResourceObject] {
        var byID: [String: AlbumsResourceObject] = [:]
        for item in included ?? [] {
            guard case .albumsResourceObject(let album) = item else { continue }
            byID[album.id] = album
        }
        return byID
    }

    // MARK: - Tracks

    /// A playlist's or an album's tracks, in its own order, capped at `limit`.
    ///
    /// Videos are dropped. TIDAL playlists can hold both, `Player` will happily
    /// play a video's audio, and a music video in the middle of a sleep playlist
    /// is a jarring thing to wake up to — so only `tracks` survive the sift.
    ///
    /// **The relationship's own `data` is the source of truth, not `included`.**
    /// This read used to require every item to come back sideloaded and dropped
    /// the ones that did not, which meant a single `include` the server chose not
    /// to honour turned a full playlist into an empty one — and an empty one is
    /// indistinguishable from a deleted one, so CribWire went on to erase the
    /// playlist from the parent's history. A relationship page is *promised* to
    /// carry the ids and types; sideloading is an optimisation on top of it. The
    /// id is the only part playback needs, so a missing title now costs a title
    /// (filled in later by `TidalMusicProvider`, which already fetches per-track
    /// metadata for the artist) rather than the track.
    /// - Returns: the tracks, or `nil` if the playlist could not be read at all.
    ///   The difference is not cosmetic: an empty answer makes `NurseryController`
    ///   delete the playlist from the parent's history, and a request that failed
    ///   has established nothing about whether the playlist still exists.
    static func tracks(in kind: MusicItemKind, id: String, limit: Int) async -> [TidalTrack]? {
        var tracks: [TidalTrack] = []
        var cursor: String?

        for page in 0 ..< maxPages {
            // A page that failed after earlier pages succeeded still played
            // something: keep what was read rather than losing a whole playlist
            // to its eighth page.
            guard let read = await itemsPage(of: kind, id: id, cursor: cursor, page: page) else {
                return tracks.isEmpty ? nil : Array(tracks.prefix(limit))
            }

            tracks.append(contentsOf: read.tracks)
            log.debug(
                """
                \(kind.rawValue, privacy: .public) \(id, privacy: .public) \
                page \(page, privacy: .public): \
                \(read.itemCount, privacy: .public) items, \
                \(read.titledCount, privacy: .public) titled, \
                \(tracks.count, privacy: .public) playable so far
                """
            )

            guard tracks.count < limit, let next = read.nextCursor else { break }
            cursor = next
        }
        return Array(tracks.prefix(limit))
    }

    /// One page of the items relationship, reduced to what the paging loop uses.
    struct ItemsPage {
        let tracks: [TidalTrack]
        /// The cursor for the page after this one, `nil` at the end of the walk.
        let nextCursor: String?
        /// Everything the page listed, videos included — logged rather than
        /// used, because "twenty items, two playable" and "two items" are the
        /// same queue and very different problems.
        let itemCount: Int
        /// How many of those tracks arrived with a title, which is how a page
        /// whose sideloading the server declined shows up in the log.
        let titledCount: Int
    }

    /// One page of items, read through the generated client and — where that
    /// client refuses the body it was given — out of the raw bytes instead.
    private static func itemsPage(
        of kind: MusicItemKind,
        id: String,
        cursor: String?,
        page: Int
    ) async -> ItemsPage? {
        do {
            let sifted: (tracks: [TidalTrack], itemCount: Int, sideloadedCount: Int)
            let next: String?
            switch kind {
            case .playlist:
                let document = try await PlaylistsAPITidal.playlistsIdRelationshipsItemsGet(
                    id: id,
                    pageCursor: cursor,
                    include: ["items"]
                )
                sifted = playableTracks(in: document)
                next = pageCursor(after: document.links.next)
            case .album:
                let document = try await AlbumsAPITidal.albumsIdRelationshipsItemsGet(
                    id: id,
                    pageCursor: cursor,
                    include: ["items"]
                )
                sifted = playableTracks(in: document)
                next = pageCursor(after: document.links.next)
            }
            return ItemsPage(
                tracks: sifted.tracks,
                nextCursor: next,
                itemCount: sifted.itemCount,
                titledCount: sifted.sideloadedCount
            )
        } catch {
            guard let salvaged = salvagedPage(from: undecodableBody(of: error)),
                  // Empty is not salvage: an error document parses as "no items"
                  // under a lenient reader, and "no items" is what makes
                  // `NurseryController` erase the playlist from the parent's
                  // history. Nothing understood establishes nothing.
                  !salvaged.tracks.isEmpty
            else {
                log.error(
                    """
                    \(kind.rawValue, privacy: .public) items request failed for \
                    \(id, privacy: .public) page \(page, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """
                )
                return nil
            }
            log.notice(
                """
                \(kind.rawValue, privacy: .public) items for \(id, privacy: .public) \
                page \(page, privacy: .public) \
                did not fit the generated models; salvaged \
                \(salvaged.tracks.count, privacy: .public) tracks from the raw body
                """
            )
            return salvaged
        }
    }

    /// One relationship page, sifted. Pulled out of the paging loop so the rule
    /// it encodes — ids are promised, sideloaded attributes are not — can be
    /// tested without a network.
    static func playableTracks(
        in document: PlaylistsItemsMultiRelationshipDataDocument
    ) -> (tracks: [TidalTrack], itemCount: Int, sideloadedCount: Int) {
        playableTracks(
            identifiers: (document.data ?? []).map { ($0.id, $0.type) },
            included: document.included
        )
    }

    /// The same rule for an album's items, which arrive in a document of the
    /// same shape and a different generated type.
    static func playableTracks(
        in document: AlbumsItemsMultiRelationshipDataDocument
    ) -> (tracks: [TidalTrack], itemCount: Int, sideloadedCount: Int) {
        playableTracks(
            identifiers: (document.data ?? []).map { ($0.id, $0.type) },
            included: document.included
        )
    }

    private static func playableTracks(
        identifiers: [(id: String, type: String)],
        included: [IncludedInner]?
    ) -> (tracks: [TidalTrack], itemCount: Int, sideloadedCount: Int) {
        let sideloaded = tracksByID(in: included)
        let tracks = identifiers
            .filter { $0.type == "tracks" }
            .map { TidalTrack(id: $0.id, title: sideloaded[$0.id]?.attributes?.title) }
        return (tracks, identifiers.count, sideloaded.count)
    }

    private static func tracksByID(in included: [IncludedInner]?) -> [String: TracksResourceObject] {
        var byID: [String: TracksResourceObject] = [:]
        for item in included ?? [] {
            guard case .tracksResourceObject(let track) = item else { continue }
            byID[track.id] = track
        }
        return byID
    }

    /// One track's title and artists, as a music app would write them.
    ///
    /// One request, for one track, made when that track starts. The alternative
    /// — resolving the whole queue up front — is a request per twenty tracks
    /// against metadata that is only ever read one line at a time, on a device
    /// whose battery is the reason the refresh loop is throttled in the first
    /// place.
    ///
    /// The title comes from `data.attributes` and the artists from `included`,
    /// which is why the title survives a server that declines the `include`:
    /// this is also the fallback for a playlist page that arrived without
    /// sideloaded titles (see `tracks(inPlaylist:)`). It is salvaged for the
    /// same reason and then some — the tracks whose attributes the generated
    /// model rejects are exactly the ones whose titles never arrived sideloaded
    /// either, so without this they would be the only tracks with no line at
    /// all under the Viewer's header.
    static func metadata(forTrack id: String) async -> (title: String?, artist: String?) {
        do {
            let document = try await TracksAPITidal.tracksIdGet(id: id, include: ["artists"])
            let names = (document.included ?? []).compactMap { item -> String? in
                guard case .artistsResourceObject(let artist) = item else { return nil }
                return artist.attributes?.name
            }
            return (
                document.data.attributes?.title,
                names.isEmpty ? nil : names.joined(separator: ", ")
            )
        } catch {
            return salvagedMetadata(from: undecodableBody(of: error))
        }
    }

    // MARK: - Reading a body the generated models refused

    /// The raw body of a response that arrived intact and would not decode.
    ///
    /// This is not a hypothetical failure and not an error on the wire. The
    /// server answers `200`; the generated `TracksAttributes` then demands eight
    /// fields a sideloaded track may simply not carry (`isrc`, `key`,
    /// `keyScale`, `popularity`…) and `PlaylistsAttributes` seven more, among
    /// them a `playlistType` whose four cases are whatever TIDAL had when the
    /// client was generated. `JSONDecoder` is all-or-nothing, so **one** track
    /// without an ISRC fails a whole playlist and one unfamiliar playlist type
    /// fails a whole library — and the generated client reports both as
    /// `HTTPErrorResponse(statusCode: 200)`, a decoding failure wearing the
    /// clothes of a transport one, with the underlying `DecodingError` dropped
    /// on the way. Between them they stopped a playlist from playing at all and
    /// hid every playlist the user had saved rather than made.
    ///
    /// So a 2xx whose body would not decode is re-read against the few things
    /// this feature actually needs. The strict path is still tried first and
    /// still preferred: it is the one that keeps the sideloaded titles when the
    /// response is clean.
    /// - Returns: the body, or `nil` for a real transport or HTTP failure —
    ///   which has nothing to salvage and must stay an error.
    private static func undecodableBody(of error: Error) -> Data? {
        guard let failure = error as? HTTPErrorResponse,
              (200 ..< 300).contains(failure.statusCode)
        else { return nil }
        return failure.data
    }

    /// The salvage for the reads that answer with playlists, with the logging
    /// they share. `nil` where the body was not a document this can read, which
    /// includes every genuine failure.
    private static func salvagedEntryPage(from error: Error, describing what: String) -> EntryPage? {
        guard let page = salvagedEntries(from: undecodableBody(of: error)),
              !page.entries.isEmpty
        else {
            log.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        log.notice(
            """
            \(what, privacy: .public) did not fit the generated models; salvaged \
            \(page.entries.count, privacy: .public) playlists from the raw body
            """
        )
        return page
    }

    /// A JSON:API document as the standard guarantees it, and no more.
    ///
    /// Every field the generated models make mandatory is optional here, and
    /// every element is wrapped so that one unreadable member costs that member
    /// alone. This is deliberately a *smaller* promise than the schema: ids and
    /// types are what playback needs, `links.next` is what paging needs, and a
    /// name or a title is welcome wherever it happens to be readable.
    private struct RawDocument: Decodable {

        struct Resource: Decodable {
            struct Attributes: Decodable {
                let title: String?
                let name: String?
                let description: String?
            }

            let id: String
            let type: String
            let attributes: Attributes?
        }

        struct PageLinks: Decodable {
            let next: String?
        }

        /// `data` is an array in a collection document and a single object in a
        /// resource one. Both are read here, because which one arrived is the
        /// endpoint's business and not this reader's.
        enum Payload: Decodable {
            case one(Lenient<Resource>)
            case many([Lenient<Resource>])

            var resources: [Resource] {
                switch self {
                case .one(let resource): return [resource.value].compactMap { $0 }
                case .many(let resources): return resources.compactMap(\.value)
                }
            }

            init(from decoder: Decoder) throws {
                if let many = try? [Lenient<Resource>](from: decoder) {
                    self = .many(many)
                } else {
                    self = .one(try Lenient<Resource>(from: decoder))
                }
            }
        }

        let data: Payload?
        let included: [Lenient<Resource>]?
        let links: PageLinks?

        var resources: [Resource] { data?.resources ?? [] }

        /// The sideloaded resources, in the order they arrived — which is the
        /// order a track's artists are meant to be read in.
        var includedResources: [Resource] { (included ?? []).compactMap(\.value) }

        /// The same, by id, for the attributes `data` carries only in some of
        /// the shapes this reads.
        var sideloaded: [String: Resource] {
            includedResources.reduce(into: [:]) { byID, resource in
                byID[resource.id] = resource
            }
        }
    }

    /// One element that is allowed to be unreadable.
    ///
    /// `JSONDecoder` fails an array if any element fails, which is exactly the
    /// all-or-nothing behaviour the salvage exists to escape.
    private struct Lenient<Wrapped: Decodable>: Decodable {
        let value: Wrapped?

        init(from decoder: Decoder) throws {
            value = try? Wrapped(from: decoder)
        }
    }

    /// The tracks and the next cursor, read out of a body the generated models
    /// rejected. `nil` when even this cannot make sense of the bytes.
    static func salvagedPage(from data: Data?) -> ItemsPage? {
        guard let document = decodeRaw(data) else { return nil }

        let sideloaded = document.sideloaded
        let tracks = document.resources
            .filter { $0.type == "tracks" }
            .map {
                TidalTrack(
                    id: $0.id,
                    title: $0.attributes?.title ?? sideloaded[$0.id]?.attributes?.title
                )
            }

        return ItemsPage(
            tracks: tracks,
            nextCursor: pageCursor(after: document.links?.next),
            itemCount: document.resources.count,
            titledCount: tracks.filter { $0.title != nil }.count
        )
    }

    /// The playlists and the next cursor, read out of a body the generated
    /// models rejected — whether they arrived as a relationship's identifiers,
    /// as full resources, or as one resource on its own.
    static func salvagedEntries(from data: Data?) -> EntryPage? {
        guard let document = decodeRaw(data) else { return nil }

        let sideloaded = document.sideloaded
        let entries = document.resources.map { resource in
            PlaylistEntry(
                id: resource.id,
                // `name` for a playlist, `title` for an album: one reader, and
                // the two words the two catalogues use for the same line.
                name: resource.attributes?.name
                    ?? resource.attributes?.title
                    ?? sideloaded[resource.id]?.attributes?.name
                    ?? sideloaded[resource.id]?.attributes?.title,
                detail: resource.attributes?.description
                    ?? sideloaded[resource.id]?.attributes?.description
            )
        }
        return EntryPage(entries: entries, nextCursor: pageCursor(after: document.links?.next))
    }

    /// One track's title and artists, read out of a body the generated models
    /// rejected.
    static func salvagedMetadata(from data: Data?) -> (title: String?, artist: String?) {
        guard let document = decodeRaw(data) else { return (nil, nil) }

        let names = document.includedResources
            .filter { $0.type == "artists" }
            .compactMap { $0.attributes?.name }
        return (
            document.resources.first?.attributes?.title,
            names.isEmpty ? nil : names.joined(separator: ", ")
        )
    }

    private static func decodeRaw(_ data: Data?) -> RawDocument? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(RawDocument.self, from: data)
    }

    // MARK: - Paging

    /// The parameter the cursor arrives under, in both the forms a JSON:API
    /// server may write it: brackets are legal unescaped in a query and TIDAL
    /// has sent them both ways.
    private static let cursorParameters = ["page[cursor]", "page%5Bcursor%5D"]

    /// The cursor out of a JSON:API `links.next`, which is a whole URL.
    ///
    /// The generated client takes a cursor, not a link, so the one has to be
    /// dug out of the other. A `next` that carries no cursor ends the walk
    /// rather than repeating the page it was found on — an unrecognised link
    /// shape must stop the loop, never spin it.
    ///
    /// Parsed by hand rather than through `URLComponents.queryItems`, because
    /// `URLComponents(string:)` refuses a URL whose query contains unescaped
    /// brackets and would turn "one more page" into "no more pages" for the
    /// exact parameter name this needs to read.
    private static func pageCursor(after next: String?) -> String? {
        guard let next, let query = next.split(separator: "?").dropFirst().first
        else { return nil }

        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, cursorParameters.contains(String(parts[0])) else { continue }
            let value = String(parts[1])
            let decoded = value.removingPercentEncoding ?? value
            return decoded.isEmpty ? nil : decoded
        }
        return nil
    }
}
