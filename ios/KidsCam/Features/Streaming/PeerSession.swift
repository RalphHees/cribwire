import Foundation
import KidsCamKit
import WebRTC

/// State of one peer connection, in terms this app cares about.
enum PeerLinkState: Equatable, Sendable {
    case new
    case checking
    case connected
    case disconnected
    case failed
    case closed

    var isUsable: Bool { self == .connected }
}

/// What a peer connection tells the engine. Deliberately plain `Sendable`
/// values: libwebrtc calls its delegate on its own threads, and nothing from
/// those threads may reach the engine's state without crossing an actor hop.
enum PeerSessionEvent: Sendable {
    case iceCandidate(sdp: String, mid: String?, mLineIndex: Int32)
    case link(PeerLinkState)
    case renegotiationNeeded
    case remoteTrackAdded
}

/// `RTCPeerConnectionDelegate` shim.
///
/// Every callback is turned into a `PeerSessionEvent` and handed to one
/// `@Sendable` closure, which hops to the owning actor. The delegate itself
/// keeps no state, so there is nothing for a background thread to race on.
final class PeerConnectionObserver: NSObject, RTCPeerConnectionDelegate {
    private let onEvent: @Sendable (PeerSessionEvent) -> Void

    init(onEvent: @escaping @Sendable (PeerSessionEvent) -> Void) {
        self.onEvent = onEvent
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        onEvent(.remoteTrackAdded)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        onEvent(.renegotiationNeeded)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onEvent(.link(Self.linkState(from: newState)))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onEvent(
            .iceCandidate(
                sdp: candidate.sdp,
                mid: candidate.sdpMid,
                mLineIndex: candidate.sdpMLineIndex
            )
        )
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    private static func linkState(from state: RTCIceConnectionState) -> PeerLinkState {
        switch state {
        case .new:
            return .new
        case .checking:
            return .checking
        case .connected, .completed:
            return .connected
        case .disconnected:
            return .disconnected
        case .failed:
            return .failed
        case .closed:
            return .closed
        case .count:
            return .new
        @unknown default:
            return .new
        }
    }
}

/// One Camera↔Viewer peer connection, plus the fingerprint that makes it
/// trustworthy.
///
/// The engine owns these; nothing outside the engine touches one. Errors are
/// deliberately coarse — a failure here is either "try again" or "someone is
/// interfering", and the second must never be softened into the first.
final class PeerSession {

    enum SessionError: Error, Equatable {
        case peerConnectionUnavailable
        case sdpUnavailable
        case localFingerprintMissing
        /// The remote certificate did not match the fingerprint that arrived in
        /// the sealed blob. `security.md` §4: hard-fail, always.
        case fingerprintMismatch(DTLSVerification)
    }

    /// The peer this session talks to: a viewer device id on the Camera, or the
    /// camera itself on the Viewer.
    let peer: SignalingRecipient
    private let connection: RTCPeerConnection
    private let observer: PeerConnectionObserver

    /// The fingerprint the peer announced inside its sealed blob, once it has
    /// arrived. Everything about trusting this connection hangs off it.
    private(set) var expectedRemoteFingerprint: DTLSFingerprint?
    private(set) var isVerified = false

    init(peer: SignalingRecipient, connection: RTCPeerConnection, observer: PeerConnectionObserver) {
        self.peer = peer
        self.connection = connection
        self.observer = observer
    }

    // MARK: - Media

    @discardableResult
    func addTrack(_ track: RTCMediaStreamTrack, streamID: String) -> RTCRtpSender? {
        connection.add(track, streamIds: [streamID])
    }

    /// Caps the encoder, so the ladder in `VideoQuality` actually bites.
    func applyBitrateCap(kbps: Int) {
        for sender in connection.senders where sender.track?.kind == "video" {
            let parameters = sender.parameters
            for encoding in parameters.encodings {
                encoding.maxBitrateBps = NSNumber(value: kbps * 1000)
            }
            sender.parameters = parameters
        }
    }

    // MARK: - Negotiation

    func makeOffer(iceRestart: Bool = false) async throws -> String {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: iceRestart ? ["IceRestart": "true"] : [:],
            optionalConstraints: nil
        )
        let description = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            connection.offer(for: constraints) { description, error in
                if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: error ?? SessionError.sdpUnavailable)
                }
            }
        }
        try await setLocal(description)
        return description.sdp
    }

    func makeAnswer() async throws -> String {
        let constraints = RTCMediaConstraints(mandatoryConstraints: [:], optionalConstraints: nil)
        let description = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            connection.answer(for: constraints) { description, error in
                if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: error ?? SessionError.sdpUnavailable)
                }
            }
        }
        try await setLocal(description)
        return description.sdp
    }

    /// Applies the peer's SDP — but only after its fingerprint has been checked
    /// against the sealed one.
    ///
    /// This is the early half of the binding in `security.md` §4: a substituted
    /// SDP is refused before DTLS is ever attempted, so a malicious backend
    /// cannot even start a handshake with us.
    func setRemote(sdp: String, type: RTCSdpType, sealedFingerprint: DTLSFingerprint?) async throws {
        let verification = DTLSFingerprintVerifier.verify(
            expected: sealedFingerprint,
            remoteSDP: sdp
        )
        guard verification.isTrusted else {
            throw SessionError.fingerprintMismatch(verification)
        }
        expectedRemoteFingerprint = sealedFingerprint

        let description = RTCSessionDescription(type: type, sdp: sdp)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func add(candidate: String, mid: String?, mLineIndex: Int32) {
        connection.add(
            RTCIceCandidate(sdp: candidate, sdpMLineIndex: mLineIndex, sdpMid: mid)
        )
    }

    /// The local `a=fingerprint`, to be sent inside the sealed blob.
    func localFingerprint() throws -> DTLSFingerprint {
        guard let sdp = connection.localDescription?.sdp,
              let fingerprint = DTLSFingerprint.fingerprints(inSDP: sdp).first
        else {
            throw SessionError.localFingerprintMissing
        }
        return fingerprint
    }

    // MARK: - Post-handshake verification

    /// Checks the certificate the DTLS handshake actually negotiated against the
    /// sealed fingerprint.
    ///
    /// The SDP check above already refuses a substituted fingerprint, and
    /// libwebrtc refuses a certificate that does not match the SDP. This is the
    /// belt to that pair of braces: it reads the fingerprint out of the peer
    /// connection's own statistics, so the value compared is the one the
    /// transport ended up with rather than the one we were told about.
    func verifyNegotiatedCertificate() async -> DTLSVerification {
        let observed = await withCheckedContinuation {
            (continuation: CheckedContinuation<DTLSFingerprint?, Never>) in
            connection.statistics { report in
                continuation.resume(returning: Self.remoteCertificateFingerprint(in: report))
            }
        }
        let verification = DTLSFingerprintVerifier.verify(
            expected: expectedRemoteFingerprint,
            observed: observed
        )
        isVerified = verification.isTrusted
        return verification
    }

    /// Pulls the remote certificate's fingerprint out of a statistics report:
    /// the selected transport names a `remoteCertificateId`, which names a
    /// certificate stat carrying `fingerprint` and `fingerprintAlgorithm`.
    static func remoteCertificateFingerprint(in report: RTCStatisticsReport) -> DTLSFingerprint? {
        var remoteCertificateIDs: [String] = []
        for (_, statistic) in report.statistics where statistic.type == "transport" {
            if let identifier = statistic.values["remoteCertificateId"] as? String {
                remoteCertificateIDs.append(identifier)
            }
        }

        for (identifier, statistic) in report.statistics where statistic.type == "certificate" {
            guard remoteCertificateIDs.isEmpty || remoteCertificateIDs.contains(identifier) else {
                continue
            }
            guard let hex = statistic.values["fingerprint"] as? String else { continue }
            let algorithm = (statistic.values["fingerprintAlgorithm"] as? String)
                ?? DTLSFingerprint.requiredAlgorithm
            if let fingerprint = DTLSFingerprint(algorithm: algorithm, hex: hex) {
                return fingerprint
            }
        }
        return nil
    }

    /// Connection statistics for the adaptive-quality ladder.
    func qualitySample() async -> AdaptiveQualityController.Sample? {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<AdaptiveQualityController.Sample?, Never>) in
            connection.statistics { report in
                continuation.resume(returning: Self.qualitySample(in: report))
            }
        }
    }

    static func qualitySample(in report: RTCStatisticsReport) -> AdaptiveQualityController.Sample? {
        var availableKbps: Int?
        var roundTrip: TimeInterval = 0
        var lost = 0.0
        var sent = 0.0

        for (_, statistic) in report.statistics {
            switch statistic.type {
            case "candidate-pair":
                if let bitrate = statistic.values["availableOutgoingBitrate"] as? NSNumber {
                    availableKbps = Int(bitrate.doubleValue / 1000)
                }
                if let rtt = statistic.values["currentRoundTripTime"] as? NSNumber {
                    roundTrip = rtt.doubleValue
                }
            case "remote-inbound-rtp":
                if let packetsLost = statistic.values["packetsLost"] as? NSNumber {
                    lost = packetsLost.doubleValue
                }
            case "outbound-rtp":
                if let packetsSent = statistic.values["packetsSent"] as? NSNumber {
                    sent = packetsSent.doubleValue
                }
            default:
                break
            }
        }

        guard let availableKbps else { return nil }
        let lossFraction = sent > 0 ? max(0, min(1, lost / sent)) : 0
        return AdaptiveQualityController.Sample(
            availableBitrateKbps: availableKbps,
            packetLossFraction: lossFraction,
            roundTripTime: roundTrip
        )
    }

    // MARK: - Teardown

    func close() {
        connection.close()
    }

    // MARK: - Private

    private func setLocal(_ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
