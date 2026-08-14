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
    /// `.mixWithOthers` is also what lets the Camera play a lullaby through this
    /// same session while it streams (`Features/Nursery`). Two consequences of
    /// `.videoChat` are worth knowing about there, and both are deliberate:
    ///
    /// - Voice processing runs on the **input**, so the music the Camera is
    ///   playing is largely cancelled out of what the Viewer hears. That is the
    ///   right way round for a monitor — the point is to hear the child, not the
    ///   playlist — and it is why the mode is not relaxed while music plays.
    /// - Voice processing can also attenuate playback on some devices. The
    ///   Viewer's volume control is the answer to that, and it moves the Camera's
    ///   own output volume rather than an app-level gain precisely so it can be.
    ///
    /// How loud the room actually ends up is hardware-dependent and has to be
    /// checked on a real pair of devices; nothing here can be asserted on a build
    /// machine.
    static func configureAudioSession(mode: AudioMode) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setCategory(
                .playAndRecord,
                with: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]
            )
            try session.setMode(.videoChat)
            try session.setActive(mode == .active)
        } catch {
            // A failed audio session downgrades the stream; it never stops it.
            // Video still flows, which is more than half of what a monitor is for.
        }
    }

    enum AudioMode {
        case active
        case inactive
    }
}
