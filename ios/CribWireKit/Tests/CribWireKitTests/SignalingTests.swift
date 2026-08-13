import XCTest
@testable import CribWireKit

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A socket that replays a script and records what was sent.
///
/// `@unchecked Sendable` with a lock rather than an actor: `SignalingSocket`
/// has a synchronous `cancel()`, which an actor can only satisfy with a
/// `nonisolated` method that cannot touch its own state.
final class ScriptedSocket: SignalingSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [String]
    private var sentFrames: [String] = []
    private var cancelled = false

    init(inbound: [String] = []) {
        self.inbound = inbound
    }

    var sent: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sentFrames
    }

    func send(text: String) async throws {
        lock.lock()
        defer { lock.unlock() }
        sentFrames.append(text)
    }

    func receive() async throws -> String {
        for _ in 0..<200 {
            lock.lock()
            if cancelled {
                lock.unlock()
                throw CocoaError(.userCancelled)
            }
            if !inbound.isEmpty {
                let next = inbound.removeFirst()
                lock.unlock()
                return next
            }
            lock.unlock()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw CocoaError(.userCancelled)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

struct ScriptedSocketFactory: SignalingSocketFactory {
    let socket: ScriptedSocket
    func connect(to url: URL, headers: [String: String]) throws -> any SignalingSocket {
        socket
    }
}

final class SignalingTests: XCTestCase {

    private var vectors: TestVectors!
    private let baseURL = URL(string: "https://api.cribwire.example")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        vectors = try TestVectors.load()
    }

    // MARK: - Envelope shape

    func testEnvelopeIsExactlyToSeqBlob() throws {
        let envelope = SignalingEnvelope(to: .viewer(deviceID: "v-1"), seq: 7, blob: "AAA=")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(envelope)) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), ["to", "seq", "blob"])
        XCTAssertEqual(json["to"] as? String, "viewer:v-1")
        XCTAssertEqual(json["seq"] as? Int, 7)
    }

    func testRecipientRoundTrip() {
        XCTAssertEqual(SignalingRecipient.camera.wireValue, "camera")
        XCTAssertEqual(SignalingRecipient.viewer(deviceID: "abc").wireValue, "viewer:abc")
        XCTAssertEqual(SignalingRecipient(wireValue: "camera"), .camera)
        XCTAssertEqual(SignalingRecipient(wireValue: "viewer:abc"), .viewer(deviceID: "abc"))
        XCTAssertNil(SignalingRecipient(wireValue: "viewer:"))
        XCTAssertNil(SignalingRecipient(wireValue: "server"))
    }

    /// The shape the server actually sends: one `peer` address, in the same form
    /// it routes on. The Camera reads the viewer's device id out of it — without
    /// that it can hear a claim but not tell who made it.
    func testPresenceEventsParseThePeerAddress() throws {
        let online = SignalingInboundMessage.parse(
            #"{"type":"peer-online","peer":"viewer:1E2C0C3E-0000-4000-8000-000000000001"}"#
        )
        XCTAssertEqual(
            online,
            .peerOnline(
                SignalingPresence(
                    role: .viewer,
                    deviceID: "1E2C0C3E-0000-4000-8000-000000000001"
                )
            )
        )

        // A camera address carries no device id: a pairing has exactly one.
        XCTAssertEqual(
            SignalingInboundMessage.parse(#"{"type":"peer-online","peer":"camera"}"#),
            .peerOnline(SignalingPresence(role: .camera, deviceID: nil))
        )

        XCTAssertEqual(
            SignalingInboundMessage.parse(
                #"{"type":"peer-offline","peer":"viewer:v-1"}"#
            ),
            .peerOffline(SignalingPresence(role: .viewer, deviceID: "v-1"))
        )
    }

    func testPresenceEventsParse() throws {
        // Fallback shape: role and device id spelled out separately.
        let online = SignalingInboundMessage.parse(
            #"{"type":"peer-online","role":"viewer","deviceId":"v-1"}"#
        )
        XCTAssertEqual(
            online,
            .peerOnline(SignalingPresence(role: .viewer, deviceID: "v-1"))
        )

        let offline = SignalingInboundMessage.parse(#"{"type":"peer-offline"}"#)
        XCTAssertEqual(offline, .peerOffline(SignalingPresence(role: nil, deviceID: nil)))

        // Unknown frames are ignored, not fatal.
        XCTAssertEqual(SignalingInboundMessage.parse(#"{"type":"pong"}"#), .unknown(type: "pong"))
        XCTAssertNil(SignalingInboundMessage.parse("not json"))
    }

    /// The payload schema is fixed by the signaling example in the shared
    /// vectors: `t`, `sdp` and `fp`.
    func testPayloadDecodesTheSharedVectorPlaintext() throws {
        let plaintext = Data(vectors.sealedEnvelope.signaling.plaintextUtf8.utf8)
        let payload = try JSONDecoder().decode(SignalingPayload.self, from: plaintext)
        XCTAssertEqual(payload.t, .offer)
        XCTAssertEqual(payload.sdp, "v=0 EXAMPLE")
        XCTAssertEqual(payload.fp, "SHA-256 AB:CD:EF")
        XCTAssertNil(payload.seq, "the vector predates the sealed seq and must still open")
    }

    // MARK: - Sealed round trip

    func testCameraToViewerRoundTripThroughTheSealedChannel() async throws {
        let socket = ScriptedSocket()
        let camera = try makeClient(role: .camera, deviceID: cameraID, socket: socket)
        let viewer = try makeClient(role: .viewer, deviceID: viewerID, socket: ScriptedSocket())

        try await camera.connect()
        try await camera.send(
            .offer(sdp: "v=0 offer", fingerprint: "sha-256 AA:BB"),
            to: .viewer(deviceID: viewerID)
        )

        let frame = try XCTUnwrap(socket.sent.first)
        // What the server sees: routing fields and opaque ciphertext.
        let onTheWire = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
        )
        XCTAssertEqual(onTheWire["to"] as? String, "viewer:\(viewerID)")
        XCTAssertEqual(onTheWire["seq"] as? Int, 1)
        let blob = try XCTUnwrap(onTheWire["blob"] as? String)
        XCTAssertFalse(frame.contains("v=0 offer"), "SDP must never appear in the clear")
        XCTAssertFalse(frame.contains("sha-256"), "the fingerprint must never appear in the clear")
        XCTAssertNotNil(Data(base64Encoded: blob))

        var events = await viewer.events.makeAsyncIterator()
        await viewer.handle(frame)
        let event = await events.next()
        guard case .received(let payload) = event else {
            return XCTFail("expected a received payload, got \(String(describing: event))")
        }
        XCTAssertEqual(payload.t, .offer)
        XCTAssertEqual(payload.sdp, "v=0 offer")
        XCTAssertEqual(payload.fp, "sha-256 AA:BB")
        XCTAssertEqual(payload.seq, 1)
        XCTAssertEqual(payload.from, cameraID)
    }

    func testSequenceNumbersAreMonotonic() async throws {
        let socket = ScriptedSocket()
        let camera = try makeClient(role: .camera, deviceID: cameraID, socket: socket)
        try await camera.connect()
        for _ in 0..<3 {
            try await camera.send(.bye(), to: .viewer(deviceID: viewerID))
        }
        let sequences: [Int] = try socket.sent.map { frame in
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
            )
            return try XCTUnwrap(json["seq"] as? Int)
        }
        XCTAssertEqual(sequences, [1, 2, 3])
    }

    // MARK: - Rejection paths

    func testReplayIsRejected() async throws {
        let frame = try await cameraFrame()
        let viewer = try makeClient(role: .viewer, deviceID: viewerID, socket: ScriptedSocket())
        var events = await viewer.events.makeAsyncIterator()

        await viewer.handle(frame)
        _ = await events.next()
        await viewer.handle(frame)
        let replayed = await events.next()
        XCTAssertEqual(replayed, .rejected(.replay))
    }

    func testRewoundSequenceIsRejected() async throws {
        let first = try await cameraFrame(payload: .bye())
        let second = try await cameraFrame(payload: .bye(), sendCount: 2)
        let viewer = try makeClient(role: .viewer, deviceID: viewerID, socket: ScriptedSocket())
        var events = await viewer.events.makeAsyncIterator()

        await viewer.handle(second)
        _ = await events.next()
        await viewer.handle(first)
        let rewound = await events.next()
        XCTAssertEqual(rewound, .rejected(.outOfOrder))
    }

    /// The attack the sealed `seq` exists for: the server rewrites the number it
    /// can see so an old blob looks new.
    func testRewritingTheOuterSequenceIsCaught() async throws {
        let frame = try await cameraFrame()
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
        )
        json["seq"] = 99
        let tampered = String(
            decoding: try JSONSerialization.data(withJSONObject: json),
            as: UTF8.self
        )

        let viewer = try makeClient(role: .viewer, deviceID: viewerID, socket: ScriptedSocket())
        var events = await viewer.events.makeAsyncIterator()
        await viewer.handle(tampered)
        let rejected = await events.next()
        XCTAssertEqual(rejected, .rejected(.sequenceMismatch))
    }

    func testTamperedBlobIsRejected() async throws {
        let frame = try await cameraFrame()
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
        )
        let blob = try XCTUnwrap(json["blob"] as? String)
        var bytes = try XCTUnwrap(Data(base64Encoded: blob))
        bytes[bytes.count - 1] ^= 0x01
        json["blob"] = bytes.base64EncodedString()
        let tampered = String(
            decoding: try JSONSerialization.data(withJSONObject: json),
            as: UTF8.self
        )

        let viewer = try makeClient(role: .viewer, deviceID: viewerID, socket: ScriptedSocket())
        var events = await viewer.events.makeAsyncIterator()
        await viewer.handle(tampered)
        let rejected = await events.next()
        XCTAssertEqual(rejected, .rejected(.sealFailed))
    }

    /// A camera must not accept a blob sealed with the camera's own AAD: that is
    /// what stops a captured camera message being reflected back at it.
    func testWrongSenderRoleIsRejected() async throws {
        let frame = try await cameraFrame(to: .camera)
        let otherCamera = try makeClient(role: .camera, deviceID: cameraID, socket: ScriptedSocket())
        var events = await otherCamera.events.makeAsyncIterator()
        await otherCamera.handle(frame)
        let rejected = await events.next()
        XCTAssertEqual(rejected, .rejected(.sealFailed))
    }

    func testWrongPairingKeyIsRejected() async throws {
        let frame = try await cameraFrame()
        let stranger = try makeClient(
            role: .viewer,
            deviceID: viewerID,
            socket: ScriptedSocket(),
            signalingKey: SymmetricKey(size: .bits256)
        )
        var events = await stranger.events.makeAsyncIterator()
        await stranger.handle(frame)
        let rejected = await events.next()
        XCTAssertEqual(rejected, .rejected(.sealFailed))
    }

    func testMessagesForOtherDevicesAreRejected() async throws {
        let frame = try await cameraFrame(to: .viewer(deviceID: "somebody-else"))
        let viewer = try makeClient(role: .viewer, deviceID: viewerID, socket: ScriptedSocket())
        var events = await viewer.events.makeAsyncIterator()
        await viewer.handle(frame)
        let rejected = await events.next()
        XCTAssertEqual(rejected, .rejected(.notForThisDevice))
    }

    func testOversizedFramesAreRejected() async throws {
        let viewer = try makeClient(role: .viewer, deviceID: viewerID, socket: ScriptedSocket())
        var events = await viewer.events.makeAsyncIterator()
        await viewer.handle(String(repeating: "x", count: SignalingEnvelope.maxMessageBytes + 1))
        let rejected = await events.next()
        XCTAssertEqual(rejected, .rejected(.oversized))
    }

    // MARK: - Sequence ledger

    func testLedgerKeepsOneWatermarkPerSender() {
        var ledger = SequenceLedger()
        XCTAssertEqual(ledger.admit(1, from: "viewer-a"), .accept)
        XCTAssertEqual(ledger.admit(2, from: "viewer-a"), .accept)
        // A second viewer starts its own numbering at 1 and must not be mistaken
        // for a replay of the first.
        XCTAssertEqual(ledger.admit(1, from: "viewer-b"), .accept)
        XCTAssertEqual(ledger.admit(2, from: "viewer-a"), .replay)
        XCTAssertEqual(ledger.admit(1, from: "viewer-a"), .outOfOrder)
        XCTAssertEqual(ledger.admit(0, from: "viewer-a"), .malformed)
        XCTAssertEqual(ledger.lastAccepted(from: "viewer-a"), 2)

        ledger.forget(sender: "viewer-a")
        XCTAssertEqual(ledger.admit(1, from: "viewer-a"), .accept)
    }

    func testGuardAllowsGapsButNotRewinds() {
        var sequenceGuard = SequenceGuard()
        XCTAssertEqual(sequenceGuard.admit(3), .accept)
        XCTAssertEqual(sequenceGuard.admit(9), .accept)
        XCTAssertEqual(sequenceGuard.admit(9), .replay)
        XCTAssertEqual(sequenceGuard.admit(4), .outOfOrder)
        XCTAssertEqual(sequenceGuard.lastAccepted, 9)
    }

    // MARK: - Helpers

    private var cameraID: String { vectors.deviceKeys.cameraDeviceId }
    private var viewerID: String { vectors.deviceKeys.viewerDeviceId }

    /// A frame as the camera would put it on the wire.
    private func cameraFrame(
        payload: SignalingPayload = .offer(sdp: "v=0 offer", fingerprint: "sha-256 AA:BB"),
        to recipient: SignalingRecipient? = nil,
        sendCount: Int = 1
    ) async throws -> String {
        let socket = ScriptedSocket()
        let camera = try makeClient(role: .camera, deviceID: cameraID, socket: socket)
        try await camera.connect()
        for _ in 0..<sendCount {
            try await camera.send(payload, to: recipient ?? .viewer(deviceID: viewerID))
        }
        return try XCTUnwrap(socket.sent.last)
    }

    private func makeClient(
        role: PairingRole,
        deviceID: String,
        socket: ScriptedSocket,
        signalingKey: SymmetricKey? = nil
    ) throws -> SignalingClient {
        let key: SymmetricKey
        if let signalingKey {
            key = signalingKey
        } else {
            key = SymmetricKey(
                data: try XCTUnwrap(Data.kc_fromHex(vectors.key("k_sig").keyHex))
            )
        }
        return SignalingClient(
            configuration: .init(
                baseURL: baseURL,
                pairingID: vectors.pairingUUID,
                role: role,
                deviceID: deviceID
            ),
            signalingKey: key,
            deviceKey: try DeviceKey(
                bytes: try XCTUnwrap(
                    Data(base64Encoded: vectors.deviceKeys.cameraDeviceKeyBase64)
                )
            ),
            factory: ScriptedSocketFactory(socket: socket),
            now: { Date(timeIntervalSince1970: 1_754_850_000) }
        )
    }
}
