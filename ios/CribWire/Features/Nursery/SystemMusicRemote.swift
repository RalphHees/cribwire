import Foundation
import MediaPlayer

/// The music already playing on the Camera phone, whoever started it.
///
/// `MusicProvider` covers the music *CribWire* started: a playlist a Viewer
/// chose, playing out of a queue this app owns. That is the wrong half of the
/// problem most of the time. A phone on a nursery shelf is usually playing
/// something the parent put on themselves, from the Music app, and until now a
/// Viewer could see none of it and stop none of it — the controls were tied to
/// CribWire's own player, which had nothing loaded.
///
/// This is the other half: `MPMusicPlayerController.systemMusicPlayer` *is* the
/// Music app, so reading it reports what the room is actually hearing and
/// pausing it actually stops the sound. It needs no subscription — a downloaded
/// or purchased library plays without one — which is the whole point.
///
/// ## What this deliberately cannot do
///
/// Reach a third-party player. iOS exposes no public API for reading or
/// controlling another app's playback, so music coming out of Spotify, YouTube or
/// a podcast app on the Camera phone is invisible to every app on that phone,
/// including this one. The volume slider is the honest answer there, and it is
/// offered unconditionally for exactly that reason.
///
/// ## Why this is not what `AppleMusicProvider` uses
///
/// That type plays playlists through `ApplicationMusicPlayer` on purpose: a
/// queue that belongs to CribWire and dies with it, so a Viewer choosing a
/// lullaby cannot rearrange what the parent was listening to elsewhere. That
/// argument does not apply to a *pause* of music already playing in the nursery,
/// which is the whole thing a parent is reaching for.
@MainActor
protocol SystemMusicRemote: AnyObject {

    /// Whether this can report or do anything at all. False until the parent has
    /// allowed music access on the Camera phone — the same permission MusicKit
    /// asks for, so the Camera's existing prompt covers both.
    var isAvailable: Bool { get }

    var isPlaying: Bool { get }
    var nowPlaying: (title: String?, artist: String?) { get }

    /// Starts and stops playback-state notifications. Without them
    /// `playbackState` is whatever it was when the controller was created.
    func start()
    func stop()

    func play()
    func pause()
    func next()
    func previous()
}

/// `SystemMusicRemote` over MediaPlayer.
@MainActor
final class MediaPlayerMusicRemote: SystemMusicRemote {

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var isObserving = false

    var isAvailable: Bool {
        MPMediaLibrary.authorizationStatus() == .authorized
    }

    var isPlaying: Bool {
        guard isAvailable else { return false }
        return player.playbackState == .playing
    }

    var nowPlaying: (title: String?, artist: String?) {
        guard isAvailable, let item = player.nowPlayingItem else { return (nil, nil) }
        return (item.title, item.artist)
    }

    func start() {
        guard isAvailable, !isObserving else { return }
        isObserving = true
        player.beginGeneratingPlaybackNotifications()
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false
        player.endGeneratingPlaybackNotifications()
    }

    // Each guarded on availability: an unauthorised app calling these does
    // nothing, and asking anyway would be a command the Camera reports as sent
    // when nothing happened.

    func play() {
        guard isAvailable else { return }
        player.play()
    }

    func pause() {
        guard isAvailable else { return }
        player.pause()
    }

    func next() {
        guard isAvailable else { return }
        player.skipToNextItem()
    }

    func previous() {
        guard isAvailable else { return }
        // Matches the button: within the first few seconds of a track this
        // restarts it rather than moving back, which is what MediaPlayer does on
        // the Lock Screen too.
        player.skipToPreviousItem()
    }
}
