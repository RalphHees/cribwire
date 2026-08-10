import Foundation

/// The plaintext inside a sealed signaling blob.
///
/// `shared/protocol.md` pins the *envelope* and leaves this schema free to
/// evolve ("Plaintext is a UTF-8 JSON document; its schema may evolve, the
/// envelope may not"). The field names `t`, `sdp` and `fp` are fixed by the
/// signaling example in `shared/test-vectors/kidscam-v1.json`:
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

    public init(
        t: Kind,
        seq: Int? = nil,
        from: String? = nil,
        sdp: String? = nil,
        fp: String? = nil,
        cand: String? = nil,
        mid: String? = nil,
        mline: Int? = nil
    ) {
        self.t = t
        self.seq = seq
        self.from = from
        self.sdp = sdp
        self.fp = fp
        self.cand = cand
        self.mid = mid
        self.mline = mline
    }

    // MARK: - Factories

    /// Camera → Viewer offer, carrying the camera's DTLS fingerprint.
    public static func offer(sdp: String, fingerprint: String) -> SignalingPayload {
        SignalingPayload(t: .offer, sdp: sdp, fp: fingerprint)
    }

    /// Viewer → Camera answer, carrying the viewer's DTLS fingerprint.
    public static func answer(sdp: String, fingerprint: String) -> SignalingPayload {
        SignalingPayload(t: .answer, sdp: sdp, fp: fingerprint)
    }

    public static func ice(candidate: String, mid: String?, mLineIndex: Int) -> SignalingPayload {
        SignalingPayload(t: .ice, cand: candidate, mid: mid, mline: mLineIndex)
    }

    public static func bye() -> SignalingPayload {
        SignalingPayload(t: .bye)
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
            mline: mline
        )
    }
}
