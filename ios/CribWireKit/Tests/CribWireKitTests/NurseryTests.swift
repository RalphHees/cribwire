import XCTest
@testable import CribWireKit

/// The nursery control vocabulary: the shortlist rule, the recents history, and
/// the wire encoding that a Camera and a Viewer on different builds have to agree
/// on.
///
/// Nothing here touches MusicKit, a torch or a socket. What can be asserted on a
/// build machine is the part that is pure — which is deliberately most of the
/// feature — and the rest is called out as needing two physical devices.
final class NurseryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_754_850_000)

    private func summary(
        _ id: String,
        provider: MusicProviderKind = .appleMusic,
        name: String? = nil,
        detail: String? = nil,
        isFavorite: Bool = false,
        lastPlayedAt: Date? = nil
    ) -> PlaylistSummary {
        PlaylistSummary(
            playlistID: id,
            provider: provider,
            name: name ?? "Playlist \(id)",
            detail: detail,
            isFavorite: isFavorite,
            lastPlayedAt: lastPlayedAt
        )
    }

    // MARK: - Shortlist

    func testCameraHistoryOutranksTheServicesOwnRecentsAndFavourites() {
        let list = PlaylistShortlist.build(
            cameraRecents: [summary("nursery", lastPlayedAt: now)],
            recentlyPlayed: [summary("commute")],
            favorites: [summary("liked", isFavorite: true)]
        )

        XCTAssertEqual(
            list.map(\.playlistID),
            ["nursery", "commute", "liked"],
            "what was played in this room has to come first"
        )
    }

    func testTheSamePlaylistFromTwoSourcesIsMergedNotRepeated() {
        let list = PlaylistShortlist.build(
            cameraRecents: [summary("sleep", lastPlayedAt: now)],
            favorites: [summary("sleep", detail: "24 songs", isFavorite: true)]
        )

        XCTAssertEqual(list.count, 1)
        // Position from the history, the star from the library: neither fact is
        // lost by the entry appearing twice.
        XCTAssertEqual(list.first?.playlistID, "sleep")
        XCTAssertTrue(list.first?.isFavorite ?? false)
        XCTAssertEqual(list.first?.detail, "24 songs")
        XCTAssertEqual(list.first?.lastPlayedAt, now)
    }

    func testTheSameIdOnTwoServicesIsTwoPlaylists() {
        let list = PlaylistShortlist.build(
            cameraRecents: [summary("42", provider: .appleMusic)],
            favorites: [summary("42", provider: .tidal)]
        )
        XCTAssertEqual(list.count, 2, "playlist ids are only unique within a service")
    }

    func testShortlistIsCapped() {
        let many = (0..<40).map { summary("p\($0)") }
        XCTAssertEqual(
            PlaylistShortlist.build(cameraRecents: many).count,
            PlaylistShortlist.limit
        )
    }

    // MARK: - Recents

    func testRecordingMovesAPlaylistToTheFrontInsteadOfDuplicatingIt() {
        var recents = PlaylistRecents()
        recents.record(playlistID: "a", provider: .appleMusic, name: "A", at: now)
        recents.record(playlistID: "b", provider: .appleMusic, name: "B", at: now + 60)
        recents.record(playlistID: "a", provider: .appleMusic, name: "A", at: now + 120)

        XCTAssertEqual(recents.entries.map(\.playlistID), ["a", "b"])
        XCTAssertEqual(recents.entries.first?.playedAt, now + 120)
    }

    func testRecentsAreCappedAtCapacityKeepingTheNewest() {
        var recents = PlaylistRecents()
        for index in 0..<(PlaylistRecents.capacity + 5) {
            recents.record(
                playlistID: "p\(index)",
                provider: .appleMusic,
                name: "P\(index)",
                at: now + TimeInterval(index)
            )
        }
        XCTAssertEqual(recents.entries.count, PlaylistRecents.capacity)
        XCTAssertEqual(recents.entries.first?.playlistID, "p\(PlaylistRecents.capacity + 4)")
    }

    func testHistoryForAServiceTheCameraCanNoLongerPlayIsNotOffered() {
        var recents = PlaylistRecents()
        recents.record(playlistID: "t1", provider: .tidal, name: "TIDAL one", at: now)
        recents.record(playlistID: "a1", provider: .appleMusic, name: "Apple one", at: now + 1)

        let offered = recents.summaries(limitedTo: [.appleMusic])
        XCTAssertEqual(offered.map(\.playlistID), ["a1"])
    }

    func testForgettingAPlaylistRemovesIt() {
        var recents = PlaylistRecents()
        recents.record(playlistID: "gone", provider: .appleMusic, name: "Gone", at: now)
        recents.forget(playlistID: "gone", provider: .appleMusic)
        XCTAssertTrue(recents.entries.isEmpty)
    }

    func testRecentsSurviveARoundTripAndStayOrdered() throws {
        var recents = PlaylistRecents()
        recents.record(playlistID: "a", provider: .appleMusic, name: "A", at: now)
        recents.record(playlistID: "b", provider: .appleMusic, name: "B", at: now + 60)

        let data = try JSONEncoder().encode(recents)
        let decoded = try JSONDecoder().decode(PlaylistRecents.self, from: data)
        XCTAssertEqual(decoded, recents)
        XCTAssertEqual(decoded.entries.map(\.playlistID), ["b", "a"])
    }

    // MARK: - Wire encoding

    func testCommandsSurviveARoundTrip() throws {
        let commands: [NurseryCommand] = [
            .music(.toggle),
            .music(.next),
            .music(.setVolume(0.42)),
            .music(.selectPlaylist(id: "abc", provider: .tidal)),
            .light(.setOn(true)),
            .light(.setLevel(0.3)),
            NurseryCommand(music: .pause, light: .setOn(false))
        ]

        for command in commands {
            let data = try JSONEncoder().encode(command)
            let decoded = try JSONDecoder().decode(NurseryCommand.self, from: data)
            XCTAssertEqual(decoded, command)
        }
    }

    /// The property that keeps a Camera and a Viewer on different builds talking:
    /// a command the Camera has never heard of must cost that one command, not the
    /// message it arrived in.
    func testACommandFromANewerBuildDecodesAsUnknownRatherThanFailing() throws {
        let json = Data(#"{"m":{"a":"shuffle","v":0.5}}"#.utf8)
        let decoded = try JSONDecoder().decode(NurseryCommand.self, from: json)

        XCTAssertEqual(decoded.music?.action, .unknown)
        XCTAssertFalse(decoded.isEmpty)
        XCTAssertNil(decoded.light)
    }

    func testAnEntirelyUnknownCommandDecodesEmptyRatherThanThrowing() throws {
        let json = Data(#"{"thermostat":{"c":21}}"#.utf8)
        let decoded = try JSONDecoder().decode(NurseryCommand.self, from: json)
        XCTAssertTrue(decoded.isEmpty, "an empty command is dropped, not guessed at")
    }

    func testVolumeAndLevelAreClampedOnBothConstructionAndDecoding() throws {
        XCTAssertEqual(MusicCommand.setVolume(9).volume, 1)
        XCTAssertEqual(MusicCommand.setVolume(-3).volume, 0)
        XCTAssertEqual(LightCommand.setLevel(9).level, 1)

        let json = Data(#"{"a":"setVolume","v":7.5}"#.utf8)
        let decoded = try JSONDecoder().decode(MusicCommand.self, from: json)
        XCTAssertEqual(decoded.volume, 1, "a Viewer cannot ask for anything out of range")
    }

    func testStateSurvivesARoundTrip() throws {
        let state = NurseryState(
            music: MusicState(
                provider: .appleMusic,
                availability: .ready,
                isPlaying: true,
                volume: 0.4,
                title: "Lullaby",
                artist: "Someone",
                playlistID: "sleep",
                playlists: [summary("sleep", isFavorite: true, lastPlayedAt: now)],
                availableProviders: [.appleMusic]
            ),
            light: LightState(availability: .ready, isOn: true, level: 0.35)
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(NurseryState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    /// An availability a Viewer has no case for must not read as "ready": the safe
    /// reading of an unrecognised music state is never "go ahead and press play".
    func testAnUnknownAvailabilityIsNotTreatedAsReady() throws {
        let json = Data(#"{"m":{"av":"needsUpgrade"},"l":{"av":"strobing"}}"#.utf8)
        let decoded = try JSONDecoder().decode(NurseryState.self, from: json)

        XCTAssertEqual(decoded.music.availability, .unknown)
        XCTAssertFalse(decoded.music.canControlPlayback)
        XCTAssertFalse(decoded.music.canChoosePlaylists)
        XCTAssertEqual(decoded.light.availability, .unknown)
        XCTAssertFalse(decoded.light.isControllable)
    }

    /// The point of the split: a lapsed subscription costs the parent the playlist
    /// picker and nothing else. Pausing what is already playing, and turning the
    /// room down, are not things anyone buys a subscription for.
    func testALapsedSubscriptionKeepsTheTransportAndLosesOnlyThePlaylists() {
        let music = MusicState(
            provider: .appleMusic,
            availability: .needsSubscription,
            canControlPlayback: true,
            isPlaying: true,
            volume: 0.3
        )
        XCTAssertTrue(music.canControlPlayback)
        XCTAssertFalse(music.canChoosePlaylists)
        XCTAssertEqual(music.volume, 0.3)
    }

    /// A Camera too old to send `ctl` said everything with `availability`, and its
    /// Viewer has to keep reading it that way — anything else would put live-looking
    /// buttons in front of a player that cannot hear them.
    func testAnOlderCameraStillDecidesTheTransportFromAvailability() throws {
        let ready = try JSONDecoder().decode(
            MusicState.self,
            from: Data(#"{"av":"ready"}"#.utf8)
        )
        XCTAssertTrue(ready.canControlPlayback)

        let lapsed = try JSONDecoder().decode(
            MusicState.self,
            from: Data(#"{"av":"needsSubscription"}"#.utf8)
        )
        XCTAssertFalse(lapsed.canControlPlayback)
    }

    func testTheTransportFlagSurvivesTheWire() throws {
        let music = MusicState(
            provider: .appleMusic,
            availability: .needsSubscription,
            canControlPlayback: true
        )
        let decoded = try JSONDecoder().decode(
            MusicState.self,
            from: try JSONEncoder().encode(music)
        )
        XCTAssertTrue(decoded.canControlPlayback)
        XCTAssertEqual(decoded, music)
    }

    func testAStateMessageFitsInsideTheSignalingFrameCap() throws {
        // The worst case the Camera can build: a full shortlist of maximum-length
        // names and details, plus a maximum-length now-playing line.
        let longest = String(repeating: "W", count: PlaylistSummary.maxNameLength * 2)
        let state = NurseryState(
            music: MusicState(
                provider: .appleMusic,
                availability: .ready,
                isPlaying: true,
                volume: 1,
                title: longest,
                artist: longest,
                playlistID: longest,
                playlists: (0..<PlaylistShortlist.limit).map {
                    summary(
                        "playlist-identifier-\($0)",
                        name: longest,
                        detail: longest,
                        isFavorite: true,
                        lastPlayedAt: now
                    )
                },
                availableProviders: MusicProviderKind.allCases
            ),
            light: LightState(availability: .ready, isOn: true, level: 1)
        )

        let payload = SignalingPayload.nursery(state)
        let encoded = try JSONEncoder().encode(payload)
        // Sealing adds a 12-byte nonce and a 16-byte tag and then base64s the lot,
        // so the plaintext has to leave room for roughly a third of itself again
        // plus the envelope around it.
        let sealedEstimate = ((encoded.count + 28) * 4 / 3) + 128
        XCTAssertLessThan(
            sealedEstimate,
            SignalingEnvelope.maxMessageBytes,
            "the shortlist and name caps are what keep this message sendable"
        )
    }

    func testLongPlaylistNamesAreTruncatedAndMarked() {
        let name = String(repeating: "a", count: 200)
        let trimmed = summary("x", name: name).name

        XCTAssertEqual(trimmed.count, PlaylistSummary.maxNameLength)
        XCTAssertTrue(trimmed.hasSuffix("…"), "a shortened name must not look like the real one")
    }

    // MARK: - Payload plumbing

    func testControlAndStateRideTheSealedSignalingPayload() throws {
        let command = NurseryCommand.music(.setVolume(0.25))
        let stamped = SignalingPayload.control(command).stamped(seq: 7, from: "device-1")

        XCTAssertEqual(stamped.t, .control)
        XCTAssertEqual(stamped.seq, 7)
        XCTAssertEqual(stamped.from, "device-1")
        XCTAssertEqual(stamped.ctl, command, "stamping must not drop the command")

        let data = try JSONEncoder().encode(stamped)
        let decoded = try JSONDecoder().decode(SignalingPayload.self, from: data)
        XCTAssertEqual(decoded, stamped)
    }

    func testStampingKeepsNurseryState() throws {
        let state = NurseryState(light: LightState(availability: .ready, isOn: true, level: 0.5))
        let stamped = SignalingPayload.nursery(state).stamped(seq: 3, from: "camera")
        XCTAssertEqual(stamped.nur, state)
    }
}
