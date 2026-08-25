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

    /// The returning-Viewer case, end to end through the client.
    ///
    /// A Viewer that closes the app and comes back builds a fresh client and
    /// numbers from 1 again, while the Camera's client has been up the whole time
    /// and still holds the old watermark. Unless it is told the peer re-attached,
    /// the Camera drops the answer and every ICE candidate behind it, and the
    /// stream can never be rebuilt.
    func testAReturningPeerIsAcceptedOnceItsWatermarkIsForgotten() async throws {
        let camera = try makeClient(role: .camera, deviceID: cameraID, socket: ScriptedSocket())
        var events = await camera.events.makeAsyncIterator()

        // The Viewer's first visit gets as far as its third message.
        let firstVisit = try await viewerFrame(payload: .bye(), sendCount: 3)
        await camera.handle(firstVisit)
        guard case .received = await events.next() else {
            return XCTFail("the first session's message should be accepted")
        }

        // It comes back with a new client, so its next answer is seq 1 again.
        let secondVisit = try await viewerFrame(
            payload: .answer(sdp: "v=0 answer", fingerprint: "sha-256 AA:BB")
        )
        await camera.handle(secondVisit)
        let staleRejection = await events.next()
        XCTAssertEqual(staleRejection, .rejected(.outOfOrder))

        await camera.forgetSender(deviceID: viewerID)
        await camera.handle(secondVisit)
        guard case .received(let payload) = await events.next() else {
            return XCTFail("a forgotten sender may start again at 1")
        }
        XCTAssertEqual(payload.t, .answer)
        XCTAssertEqual(payload.seq, 1)
    }

    /// A Camera announces itself as `camera` with no device id, so a Viewer has
    /// no name to forget — and needs none, having exactly one peer.
    func testForgettingEverySenderLetsAReconnectedCameraStartAgain() async throws {
        let viewer = try makeClient(role: .viewer, deviceID: viewerID, socket: ScriptedSocket())
        var events = await viewer.events.makeAsyncIterator()

        await viewer.handle(try await cameraFrame(payload: .bye(), sendCount: 4))
        guard case .received = await events.next() else {
            return XCTFail("the first session's message should be accepted")
        }

        let afterReconnect = try await cameraFrame(payload: .bye())
        await viewer.handle(afterReconnect)
        let staleRejection = await events.next()
        XCTAssertEqual(staleRejection, .rejected(.outOfOrder))

        await viewer.forgetAllSenders()
        await viewer.handle(afterReconnect)
        guard case .received = await events.next() else {
            return XCTFail("a forgotten sender may start again at 1")
        }
    }

    /// `forgetAllSenders` must leave the outbound counter alone: the server drops
    /// any frame whose `seq` does not increase strictly on the connection, so a
    /// rewind here would silence this client for the rest of the socket's life.
    func testForgettingSendersDoesNotRewindOutboundNumbering() async throws {
        let socket = ScriptedSocket()
        let camera = try makeClient(role: .camera, deviceID: cameraID, socket: socket)
        try await camera.connect()
        try await camera.send(.bye(), to: .viewer(deviceID: viewerID))
        await camera.forgetAllSenders()
        try await camera.send(.bye(), to: .viewer(deviceID: viewerID))

        let sequences: [Int] = try socket.sent.map { frame in
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
            )
            return try XCTUnwrap(json["seq"] as? Int)
        }
        XCTAssertEqual(sequences, [1, 2])
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

    /// A frame as the viewer would put it on the wire.
    private func viewerFrame(
        payload: SignalingPayload = .answer(sdp: "v=0 answer", fingerprint: "sha-256 AA:BB"),
        sendCount: Int = 1
    ) async throws -> String {
        let socket = ScriptedSocket()
        let viewer = try makeClient(role: .viewer, deviceID: viewerID, socket: socket)
        try await viewer.connect()
        for _ in 0..<sendCount {
            try await viewer.send(payload, to: .camera)
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

/// The upgrade MAC is a pure function of the second, because every other input is
/// constant for a given device. Two attempts in one second are therefore
/// byte-identical and the second is refused as a replay — for two minutes, which
/// is how a reconnect ladder gets stuck.
final class RequestTimestampSequencerTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_754_850_000)

    func testPassesTheClockThroughWhenItIsMovingOn() {
        var sequencer = RequestTimestampSequencer()
        XCTAssertEqual(sequencer.next(after: base), base)
        XCTAssertEqual(sequencer.next(after: base + 1), base + 1)
        XCTAssertEqual(sequencer.next(after: base + 30), base + 30)
    }

    /// The case that breaks reconnects: two attempts inside one second.
    func testNeverReturnsTheSameSecondTwice() {
        var sequencer = RequestTimestampSequencer()
        XCTAssertEqual(sequencer.next(after: base), base)
        XCTAssertEqual(sequencer.next(after: base), base + 1)
        XCTAssertEqual(sequencer.next(after: base), base + 2)
    }

    /// Sub-second instants collapse to the same whole second, so they collide too.
    func testTreatsSubSecondInstantsAsTheSameSecond() {
        var sequencer = RequestTimestampSequencer()
        XCTAssertEqual(sequencer.next(after: base + 0.1), base)
        XCTAssertEqual(sequencer.next(after: base + 0.9), base + 1)
    }

    /// A clock that steps backwards — NTP correcting, or a device waking — must
    /// not hand back a second already spent.
    func testDoesNotReuseASecondWhenTheClockGoesBackwards() {
        var sequencer = RequestTimestampSequencer()
        XCTAssertEqual(sequencer.next(after: base + 10), base + 10)
        XCTAssertEqual(sequencer.next(after: base), base + 11)
    }

    /// Once the real clock catches up, the sequencer stops running ahead.
    func testStopsDriftingOnceTheClockOvertakesIt() {
        var sequencer = RequestTimestampSequencer()
        for _ in 0..<5 { _ = sequencer.next(after: base) }
        XCTAssertEqual(sequencer.drift(from: base), 4)

        XCTAssertEqual(sequencer.next(after: base + 60), base + 60)
        XCTAssertEqual(sequencer.drift(from: base + 60), 0)
    }

    /// Drift stays far inside the server's 60 s window even under the fastest
    /// backoff the reconnect ladder ever uses.
    func testDriftStaysWithinTheServersSkewWindow() {
        var sequencer = RequestTimestampSequencer()
        // Ten immediate retries is well beyond what `ReconnectPolicy` produces.
        for _ in 0..<10 { _ = sequencer.next(after: base) }
        XCTAssertLessThan(sequencer.drift(from: base), 60)
    }
}

/// Device names: the rules a name has to obey to be put on the wire, and the
/// promise that a peer too old to send one costs nothing.
///
/// Names are the one string in this protocol typed by a person on another
/// device and drawn unescaped on this one, so what is asserted here is mostly
/// what happens to a hostile one.
final class DeviceNameTests: XCTestCase {

    func testNamesAreTrimmedAndCollapsed() {
        XCTAssertEqual(DeviceName.sanitized("  Nursery  "), "Nursery")
        XCTAssertEqual(DeviceName.sanitized("Kitchen\tiPad"), "Kitchen iPad")
    }

    /// Line breaks are stripped rather than escaped.
    ///
    /// A name is drawn in a single-line row beside a Remove button. A peer that
    /// sent forty newlines could otherwise push that button off the screen of
    /// the device it is paired with — cheap to prevent here, impossible to fix
    /// once it is stored.
    func testLineBreaksCannotSurviveInAName() {
        let hostile = "Nursery\n\n\n\n\nRemove"
        let sanitized = DeviceName.sanitized(hostile)

        XCTAssertEqual(sanitized, "Nursery Remove")
        XCTAssertFalse(sanitized?.contains("\n") ?? true)
    }

    /// A name that says nothing is `nil`, not an empty string: the UI draws the
    /// peer's *role* for a nameless device, and it can only do that if "no name"
    /// is a case rather than a blank.
    func testAnEmptyNameIsNoName() {
        XCTAssertNil(DeviceName.sanitized(""))
        XCTAssertNil(DeviceName.sanitized("   \n\t "))
    }

    func testLongNamesAreCappedAndMarked() {
        let long = String(repeating: "a", count: 200)
        let capped = DeviceName.sanitized(long)

        XCTAssertEqual(capped?.count, DeviceName.maxLength)
        XCTAssertTrue(capped?.hasSuffix("…") ?? false, "a shortened name must not look like the real one")
    }

    /// Sanitising happens on decode too, not only on the way out. The encoder at
    /// the other end is another device on another build, which this one has no
    /// say over.
    func testAHostileNameIsSanitisedOnTheWayIn() throws {
        let json = #"{"d":"viewer:abc","n":"  Bad\n\nName  "}"#
        let decoded = try JSONDecoder().decode(ConnectedDevice.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.name, "Bad Name")
        XCTAssertEqual(decoded.deviceID, "viewer:abc")
    }

    /// The roster is capped at the pairing limit. A peer claiming more is either
    /// broken or malicious, and either way the answer is to stop reading.
    func testTheRosterIsCappedAtThePairingLimit() {
        let crowd = (0..<50).map { ConnectedDevice(deviceID: "viewer:\($0)", name: "V\($0)") }
        let payload = SignalingPayload.status(
            batteryLevel: 0.5,
            isCharging: false,
            name: "Nursery",
            viewers: crowd
        )

        XCTAssertEqual(payload.vws?.count, DeviceName.maxRoster)
    }

    /// A name survives the round trip on every message type that carries one.
    ///
    /// Four types carry it because a name is something a peer mentions while
    /// doing something else — there is no "my name is" message — and each path
    /// is the only one some pairing has: local pairings introduce with `hello`,
    /// server pairings with offer/answer, and `status` is what keeps a Viewer up
    /// to date afterwards.
    func testNamesSurviveEveryMessageThatCarriesThem() throws {
        let payloads = [
            SignalingPayload.hello(name: "Nursery"),
            SignalingPayload.offer(sdp: "v=0", fingerprint: "sha-256 AA", name: "Nursery"),
            SignalingPayload.answer(sdp: "v=0", fingerprint: "sha-256 BB", name: "Kitchen"),
            SignalingPayload.status(batteryLevel: 0.4, isCharging: true, name: "Nursery")
        ]

        for payload in payloads {
            let data = try JSONEncoder().encode(payload)
            let decoded = try JSONDecoder().decode(SignalingPayload.self, from: data)
            XCTAssertEqual(decoded.nm, payload.nm, "\(payload.t) dropped the name")
        }
    }

    /// Stamping is what `SignalingClient` does on the way out, and it rebuilds
    /// the payload field by field — so a field added without being stamped is
    /// silently dropped on every real send while every test that skips stamping
    /// passes.
    func testStampingKeepsTheNameAndTheRoster() {
        let payload = SignalingPayload.status(
            batteryLevel: 0.9,
            isCharging: false,
            name: "Nursery",
            viewers: [ConnectedDevice(deviceID: "viewer:1", name: "Kitchen")]
        )
        let stamped = payload.stamped(seq: 4, from: "camera")

        XCTAssertEqual(stamped.nm, "Nursery")
        XCTAssertEqual(stamped.vws?.first?.name, "Kitchen")
        XCTAssertEqual(stamped.seq, 4)
    }

    /// A peer that predates names costs nothing: the fields are absent, the
    /// message still decodes, and every screen falls back to the role.
    func testAMessageWithoutANameStillDecodes() throws {
        let json = #"{"t":"status","batt":0.5,"chg":false}"#
        let decoded = try JSONDecoder().decode(SignalingPayload.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.t, .status)
        XCTAssertNil(decoded.nm)
        XCTAssertNil(decoded.vws, "no roster is not the same as an empty room")
        XCTAssertEqual(decoded.batt, 0.5)
    }

    /// A full roster of the longest permissible names still fits the signaling
    /// frame, with the battery and everything else in the same message.
    func testAFullRosterFitsTheSignalingFrame() throws {
        let longest = String(repeating: "W", count: DeviceName.maxLength)
        let payload = SignalingPayload.status(
            batteryLevel: 0.5,
            isCharging: true,
            name: longest,
            viewers: (0..<DeviceName.maxRoster).map {
                ConnectedDevice(
                    deviceID: "viewer:\(UUID().uuidString)-\($0)",
                    name: longest,
                    since: Date()
                )
            }
        )

        let encoded = try JSONEncoder().encode(payload.stamped(seq: 1, from: "camera"))
        // Sealing adds a 12-byte nonce and a 16-byte tag and then base64s the
        // lot, so the plaintext has to leave room for a third of itself again
        // plus the envelope around it.
        let sealedEstimate = ((encoded.count + 28) * 4 / 3) + 128
        XCTAssertLessThan(
            sealedEstimate,
            SignalingEnvelope.maxMessageBytes,
            "the name and roster caps are what keep this message sendable"
        )
    }
}
