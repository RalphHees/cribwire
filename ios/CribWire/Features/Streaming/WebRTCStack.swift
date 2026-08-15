import AVFoundation
import Foundation
import CribWireKit
import WebRTC

/// The process-wide libwebrtc setup.
///
/// libwebrtc wants `RTCInitializeSSL()` called once per process and one factory
/// shared by everything that builds a peer connection — creating a second
/// factory spins up a second set of worker threads and a second encoder pool for
/// no benefit. This is that single owner.
///
/// The video codec factories are the *default* ones on purpose: they resolve to
/// VideoToolbox H.264 on iOS hardware, which is what `ios-app.md` §3 asks for and
/// what keeps the Camera's battery budget reachable.
enum WebRTCStack {

    /// Media stream id used for every track this app publishes. WebRTC needs the
    /// audio and video tracks grouped, and one pairing only ever has one stream.
    static let streamID = "cribwire"

    private static let initializeOnce: Void = {
        RTCInitializeSSL()
        // Errors only; libwebrtc's info logging is extremely chatty and would
        // put connection details into the device console.
        RTCSetMinDebugLogLevel(.error)
    }()

    static let factory: RTCPeerConnectionFactory = {
        _ = initializeOnce
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    /// Builds the peer-connection configuration for a pairing.
    ///
    /// STUN comes first and TURN second so a LAN pair — the common case for a
    /// baby monitor, both devices on the same Wi-Fi — connects directly and never
    /// relays. TURN is the fallback that makes "across networks" work at all.
    static func configuration(turn: API.TurnCredentialsResponse?) -> RTCConfiguration {
        let configuration = RTCConfiguration()
        var servers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        if let turn, !turn.uris.isEmpty {
            servers.append(
                RTCIceServer(
                    urlStrings: turn.uris,
                    username: turn.username,
                    credential: turn.credential
                )
            )
        }
        configuration.iceServers = servers
        configuration.sdpSemantics = .unifiedPlan
        // Keep gathering after the first candidate set: a Wi-Fi→cellular switch
        // needs new candidates without a full renegotiation.
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require

        // --- Candidate hygiene -------------------------------------------
        //
        // Left alone, ICE gathers on every interface iOS reports: Wi-Fi (one
        // address per IPv4/IPv6/ULA), the AWDL link-local `en2`, both cellular
        // PDP contexts, and any VPN tunnel. With four TURN URIs that is dozens of
        // relay allocations and a candidate matrix to match, most of it hopeless.
        // Every useless pair still has to be tried before ICE gives up, so this
        // is not merely wasteful — it is latency a returning Viewer waits through.

        // Link-local (169.254/AWDL) can never reach the peer or the TURN server;
        // it produces nothing but EHOSTUNREACH. This is the single biggest source
        // of noise in the device logs.
        configuration.disableLinkLocalNetworks = true

        // One IPv6 network is enough. A phone routinely has three (link-local,
        // ULA, global), and each multiplies the pairs to check.
        configuration.maxIPv6Networks = 1

        // Pre-gather a small pool so the first offer already carries candidates
        // rather than waiting for trickle to catch up.
        configuration.iceCandidatePoolSize = 1

        // Deliberately *not* set: `candidateNetworkPolicy = .lowCost` would drop
        // cellular, which is exactly the interface a Viewer away from home needs.
        // Certificates are per-connection, and the fingerprint of this one is
        // what the sealed blob binds (`security.md` §4).
        return configuration
    }

    /// Media constraints for a peer connection. Nothing mandatory: the tracks
    /// added to the connection decide what is negotiated.
    static func defaultConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }

    /// Configures the shared audio session for streaming.
    ///
    /// `playAndRecord` on both sides: the Camera records room audio, and the
    /// Viewer plays it. `.mixWithOthers` keeps the app from stopping the user's
    /// music the moment a Viewer opens; `.defaultToSpeaker` stops Viewer audio
    /// coming out of the earpiece.
    ///
    /// `.mixWithOthers` is also what lets a lullaby keep playing in the room while
    /// the Camera streams (`Features/Nursery`).
    ///
    /// The **mode differs by role**, and the reason is volume rather than audio
    /// quality — see `sessionMode(for:)`. The short version: a voice mode moves
    /// the device into the call volume, and the Camera's music lives in the media
    /// volume, so a Camera in a voice mode has a music slider that controls
    /// nothing anyone can hear.
    ///
    /// How loud the room actually ends up is hardware-dependent and has to be
    /// checked on a real pair of devices; nothing here can be asserted on a build
    /// machine.
    @MainActor
    static func configureAudioSession(mode: AudioMode, output: AudioOutput = .followRoute) {
        let sessionMode = sessionMode(for: output)
        teachWebRTC(sessionMode)

        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setCategory(.playAndRecord, with: categoryOptions)
            try session.setMode(sessionMode)
            // Only on a real change. `RTCAudioSession` counts activations and
            // expects them balanced, and this is called repeatedly with the same
            // intent — on every route change, after every interruption, from the
            // detector as well as the engine. Calling it each time ran the count
            // up, and the single `setActive(false)` in `stop()` could then never
            // bring it back to zero: the Camera would hold the audio session, and
            // the recording indicator with it, long after the monitor stopped.
            if isActive != (mode == .active) {
                try session.setActive(mode == .active)
                isActive = mode == .active
            }
            if mode == .active, output == .room, isRoutedToEarpiece(session) {
                try session.overrideOutputAudioPort(.speaker)
            }
        } catch {
            // A failed audio session downgrades the stream; it never stops it.
            // Video still flows, which is more than half of what a monitor is for.
        }
    }

    /// Whether *this app* has asked for the session, so the asks stay balanced.
    @MainActor
    private static var isActive = false

    private static let categoryOptions: AVAudioSession.CategoryOptions =
        [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]

    /// Replaces the configuration libwebrtc applies to the audio session on its
    /// own initiative.
    ///
    /// **This is what made talk-back inaudible on the Camera.** Everything above
    /// configures the session correctly and then libwebrtc's audio device module,
    /// when it starts playout or recording, applies
    /// `RTCAudioSessionConfiguration.webRTCConfiguration` over the top of it. Its
    /// defaults are `playAndRecord` + `voiceChat` + `allowBluetooth` — and
    /// crucially **no `defaultToSpeaker`**, so the session it leaves behind routes
    /// playback to the built-in receiver. On a phone held to an ear that is
    /// correct; on a phone lying face-up in a cot room it means the parent's voice
    /// comes out of the earpiece, which from anywhere in the room is silence.
    ///
    /// Nothing else was affected, which is why this was invisible: recording is
    /// unaffected by the output route, so the Viewer kept hearing the room, and
    /// the music comes from the Music app's own session and kept using the
    /// speaker. Only the one path that plays through libwebrtc went missing.
    ///
    /// Overriding the configuration — rather than re-asserting ours afterwards —
    /// is the fix, because the ADM re-applies it on every restart: an
    /// interruption, a route change, a rebuilt peer connection. There is no
    /// moment after which re-asserting would be safe.
    private static func teachWebRTC(_ sessionMode: AVAudioSession.Mode) {
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.categoryOptions = categoryOptions
        configuration.mode = sessionMode.rawValue
        RTCAudioSessionConfiguration.setWebRTC(configuration)
    }

    /// Which mode this device's job needs — and, inseparably, which volume the
    /// hardware buttons and the Viewer's slider will move.
    ///
    /// This is the part that is easy to get wrong twice. iOS keeps separate
    /// volumes for media and for calls, and an active `playAndRecord` session in
    /// a voice mode puts the device in the *call* volume. The Camera's music is
    /// usually not ours — a parent starts something in the Music app, which plays
    /// in the *media* volume — so a Camera in a voice mode has a music slider
    /// that moves a volume nothing audible is using.
    ///
    /// So the Camera stays in `.default`. What it gives up is the session-level
    /// declaration of voice chat; what it keeps is the echo cancellation that
    /// actually matters, because libwebrtc records through a
    /// `VoiceProcessingIO` audio unit either way — the cancellation lives in the
    /// unit, not in the mode. The Viewer has no such conflict: nothing else on
    /// that phone is making noise, so it keeps `.videoChat`.
    private static func sessionMode(for output: AudioOutput) -> AVAudioSession.Mode {
        switch output {
        case .room: return .default
        case .followRoute: return .videoChat
        }
    }

    /// Whether playback is currently going to the earpiece.
    ///
    /// Checked rather than overridden unconditionally: `.speaker` forces the
    /// built-in speaker even when headphones or a Bluetooth speaker are
    /// connected, and a Camera paired to a speaker for lullabies should keep
    /// using it. The earpiece is the one route that is always wrong for a phone
    /// nobody is holding.
    private static func isRoutedToEarpiece(_ session: RTCAudioSession) -> Bool {
        session.currentRoute.outputs.contains { $0.portType == .builtInReceiver }
    }

    enum AudioMode {
        case active
        case inactive
    }

    /// Where playback should come out.
    enum AudioOutput {
        /// A phone on a shelf. Playback belongs in the room, and never in an
        /// earpiece nobody is holding.
        case room
        /// Whatever the route says. The Viewer is a phone in someone's hand, and
        /// holding it to an ear at 3 a.m. is a reasonable thing to do with it.
        case followRoute
    }
}
