import Foundation

/// The plaintext inside a sealed signaling blob.
///
/// `shared/protocol.md` pins the *envelope* and leaves this schema free to
/// evolve ("Plaintext is a UTF-8 JSON document; its schema may evolve, the
/// envelope may not"). The field names `t`, `sdp` and `fp` are fixed by the
/// signaling example in `shared/test-vectors/cribwire-v1.json`:
///
/// ```json
/// {"t":"offer","sdp":"v=0 EXAMPLE","fp":"SHA-256 AB:CD:EF"}
/// ```
///
/// Two fields are added on top of it, and both exist for security rather than
/// convenience:
///
/// - `seq` repeats the envelope's sequence number *inside* the seal, so a server
///   that rewrites the outer `seq` to replay an old blob is caught.
/// - `from` is the sender's device id, sealed, so a Camera talking to several
///   Viewers can keep one replay ledger per authenticated sender instead of
///   trusting a routing field the server controls.
///
/// `fp` is the local DTLS certificate fingerprint. Carrying it in here is what
/// makes a compromised backend unable to man-in-the-middle the media
/// (`security.md` §4): the peer compares the certificate it actually negotiated
/// against a value only the QR-derived key could have produced.
public struct SignalingPayload: Codable, Equatable, Sendable {

    public enum Kind: String, Codable, Equatable, Sendable {
        case offer
        case answer
        case ice
        /// Graceful teardown, so the peer can stop instead of waiting for ICE
        /// to time out.
        case bye
        /// First message on a local-network pairing link, in both directions.
        ///
        /// On the server path the backend issues device ids and announces a claim
        /// with `peer-online`. Offline there is no backend to do either, so each
        /// side mints its own id and introduces itself. The id is carried by
        /// `from`, which `SignalingClient` stamps *inside* the seal — so a peer
        /// that cannot open the envelope cannot introduce itself at all, and
        /// possession of the QR secret is the whole of the authentication.
        case hello
        /// Camera → Viewer device status: battery, and whether it is charging.
        ///
        /// It travels sealed, like everything else on this channel, so the server
        /// never learns the state of anyone's device. A Viewer showing "Camera at
        /// 12 %" is answering the question behind most failed nights — the Camera
        /// quietly went flat — which is worth a message type of its own.
        case status
        /// Viewer → Camera: change the music, the light, how bright the picture
        /// is, or what the Camera raises an alert about.
        ///
        /// The only message in the protocol that *acts* on the Camera rather than
        /// describing it, which is why the Camera checks two things before obeying
        /// one: that it came from a Viewer (a Camera receiving it would mean
        /// someone is impersonating one), and that the sender has a session whose
        /// certificate was verified. The seal already proves possession of the QR
        /// secret; the session check means the sender is the peer this Camera is
        /// actually streaming to, not merely someone who once scanned the code.
        case control
        /// Camera → Viewer: what the music, the light, the exposure and the
        /// alert settings are currently set to.
        ///
        /// Sent on every change, and once to each Viewer as it verifies — exactly
        /// like `status`. The Viewer holds no independent notion of the state, it
        /// draws this, so a control that appears to have taken effect always has.
        case nursery
    }

    /// Message type.
    public let t: Kind
    /// Sequence number, mirrored from the envelope.
    public let seq: Int?
    /// Sender's device id.
    public let from: String?
    /// SDP text, for `offer` and `answer`.
    public let sdp: String?
    /// `a=fingerprint` value of the sender's DTLS certificate, e.g.
    /// `sha-256 AB:CD:…`.
    public let fp: String?
    /// ICE candidate SDP line.
    public let cand: String?
    /// `sdpMid` of the candidate.
    public let mid: String?
    /// `sdpMLineIndex` of the candidate.
    public let mline: Int?
    /// Battery level `0...1`, for `status`. Absent when unknown.
    public let batt: Double?
    /// Whether the sender is charging, for `status`.
    public let chg: Bool?
    /// The requested change, for `control`.
    public let ctl: NurseryCommand?
    /// The music and light state, for `nursery`.
    public let nur: NurseryState?
    /// The sender's own device name, already sanitised by `DeviceName`.
    ///
    /// Rides on `hello`, `offer`, `answer` and `status` — every message that
    /// starts or maintains a session — rather than getting a message type of its
    /// own. That is what makes a name arrive on both paths without new plumbing:
    /// a local-network pairing introduces itself with `hello`, a server pairing
    /// with the offer/answer exchange, and neither has to know about the other.
    ///
    /// Absent from a peer running a build that predates names, which is drawn as
    /// a role — "Viewer" — rather than as an empty row.
    public let nm: String?
    /// Camera → Viewer: who else is watching this room, for `status`.
    ///
    /// The Camera is the only device that can know this. Viewers hold a session
    /// with the Camera and with nobody else — there is no peer-to-peer mesh and
    /// deliberately so — so a Viewer showing "two others watching" is showing
    /// something only the Camera could have told it.
    public let vws: [ConnectedDevice]?

    public init(
        t: Kind,
        seq: Int? = nil,
        from: String? = nil,
        sdp: String? = nil,
        fp: String? = nil,
        cand: String? = nil,
        mid: String? = nil,
        mline: Int? = nil,
        batt: Double? = nil,
        chg: Bool? = nil,
        ctl: NurseryCommand? = nil,
        nur: NurseryState? = nil,
        nm: String? = nil,
        vws: [ConnectedDevice]? = nil
    ) {
        self.t = t
        self.seq = seq
        self.from = from
        self.sdp = sdp
        self.fp = fp
        self.cand = cand
        self.mid = mid
        self.mline = mline
        self.batt = batt
        self.chg = chg
        self.ctl = ctl
        self.nur = nur
        self.nm = nm.flatMap(DeviceName.sanitized)
        // Capped on the way out as well as on the way in: a Camera with a
        // runaway session table must not be the thing that produces a message
        // too large for the frame it has to fit in.
        self.vws = vws.map { Array($0.prefix(DeviceName.maxRoster)) }
    }

    // MARK: - Factories

    /// Camera → Viewer offer, carrying the camera's DTLS fingerprint and the
    /// name the Camera goes by.
    public static func offer(
        sdp: String,
        fingerprint: String,
        name: String? = nil
    ) -> SignalingPayload {
        SignalingPayload(t: .offer, sdp: sdp, fp: fingerprint, nm: name)
    }

    /// Viewer → Camera answer, carrying the viewer's DTLS fingerprint and name.
    public static func answer(
        sdp: String,
        fingerprint: String,
        name: String? = nil
    ) -> SignalingPayload {
        SignalingPayload(t: .answer, sdp: sdp, fp: fingerprint, nm: name)
    }

    public static func ice(candidate: String, mid: String?, mLineIndex: Int) -> SignalingPayload {
        SignalingPayload(t: .ice, cand: candidate, mid: mid, mline: mLineIndex)
    }

    public static func bye() -> SignalingPayload {
        SignalingPayload(t: .bye)
    }

    /// Local-network introduction. The sender's device id rides in `from`,
    /// stamped inside the seal by `SignalingClient`.
    public static func hello(name: String? = nil) -> SignalingPayload {
        SignalingPayload(t: .hello, nm: name)
    }

    /// Camera → Viewer battery report.
    ///
    /// - Parameter level: `0...1`, or negative when iOS has not measured it yet.
    ///   A negative reading is sent as `nil` rather than as a number, so the
    ///   Viewer can show "unknown" instead of "0 %" and frighten someone.
    public static func status(
        batteryLevel: Double,
        isCharging: Bool,
        name: String? = nil,
        viewers: [ConnectedDevice]? = nil
    ) -> SignalingPayload {
        SignalingPayload(
            t: .status,
            batt: batteryLevel >= 0 ? batteryLevel : nil,
            chg: isCharging,
            nm: name,
            vws: viewers
        )
    }

    /// Viewer → Camera nursery control.
    public static func control(_ command: NurseryCommand) -> SignalingPayload {
        SignalingPayload(t: .control, ctl: command)
    }

    /// Camera → Viewer nursery state.
    public static func nursery(_ state: NurseryState) -> SignalingPayload {
        SignalingPayload(t: .nursery, nur: state)
    }

    // MARK: - Stamping

    /// Returns a copy stamped with the sequence number and sender identity that
    /// go inside the seal. `SignalingClient` does this on the way out; callers
    /// never set `seq` themselves.
    func stamped(seq: Int, from: String) -> SignalingPayload {
        SignalingPayload(
            t: t,
            seq: seq,
            from: from,
            sdp: sdp,
            fp: fp,
            cand: cand,
            mid: mid,
            mline: mline,
            batt: batt,
            chg: chg,
            ctl: ctl,
            nur: nur,
            nm: nm,
            vws: vws
        )
    }
}
