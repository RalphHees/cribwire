import XCTest
@testable import CribWireKit

/// Reassembly is where a hand-rolled framing protocol goes wrong, and the failure
/// is silent: a stream that loses alignment does not crash, it just delivers
/// nonsense that fails to decrypt for ever after. These drive the decoder with the
/// chunk boundaries a real network produces.
final class LocalFramingTests: XCTestCase {

    private func decode(_ chunks: [Data]) throws -> [String] {
        var decoder = LocalFraming.Decoder()
        var out: [String] = []
        for chunk in chunks {
            out += try decoder.append(chunk)
        }
        return out
    }

    func testRoundTripsASingleMessage() throws {
        let frame = try XCTUnwrap(LocalFraming.encode("hello"))
        XCTAssertEqual(try decode([frame]), ["hello"])
    }

    /// Two envelopes arriving in one read — routine when a peer sends an offer
    /// and its first ICE candidate back to back.
    func testSplitsTwoMessagesDeliveredInOneRead() throws {
        var combined = try XCTUnwrap(LocalFraming.encode("first"))
        combined.append(try XCTUnwrap(LocalFraming.encode("second")))
        XCTAssertEqual(try decode([combined]), ["first", "second"])
    }

    /// One envelope split across reads. Delivered byte at a time, which is the
    /// worst case the network can produce and the one most likely to expose an
    /// off-by-one in the length handling.
    func testReassemblesAMessageArrivingOneByteAtATime() throws {
        let frame = try XCTUnwrap(LocalFraming.encode("a longer message body"))
        let chunks = frame.map { Data([$0]) }
        XCTAssertEqual(try decode(chunks), ["a longer message body"])
    }

    /// A frame boundary landing mid-header is the case a naive implementation
    /// gets wrong: it needs four bytes before it can even know the length.
    func testHoldsAPartialLengthPrefix() throws {
        let frame = try XCTUnwrap(LocalFraming.encode("payload"))
        var decoder = LocalFraming.Decoder()
        XCTAssertEqual(try decoder.append(frame.prefix(2)), [])
        XCTAssertEqual(decoder.pendingByteCount, 2)
        XCTAssertEqual(try decoder.append(Data(frame.dropFirst(2))), ["payload"])
        XCTAssertEqual(decoder.pendingByteCount, 0)
    }

    func testHoldsAPartialBodyWithoutEmittingIt() throws {
        let frame = try XCTUnwrap(LocalFraming.encode("payload"))
        var decoder = LocalFraming.Decoder()
        XCTAssertEqual(try decoder.append(frame.dropLast(3)), [])
        XCTAssertEqual(try decoder.append(Data(frame.suffix(3))), ["payload"])
    }

    func testCarriesUnicodeIntact() throws {
        let text = #"{"blob":"señal · 日本語 · 🍼"}"#
        let frame = try XCTUnwrap(LocalFraming.encode(text))
        XCTAssertEqual(try decode([frame]), [text])
    }

    func testEmptyMessageIsAValidFrame() throws {
        let frame = try XCTUnwrap(LocalFraming.encode(""))
        XCTAssertEqual(try decode([frame]), [""])
    }

    // MARK: - Limits

    func testRefusesToEncodeAboveTheFrameCap() {
        let tooBig = String(repeating: "x", count: LocalFraming.maxFrameBytes + 1)
        XCTAssertNil(LocalFraming.encode(tooBig))
        XCTAssertNotNil(LocalFraming.encode(String(repeating: "x", count: LocalFraming.maxFrameBytes)))
    }

    /// An announced length above the cap must be rejected on the header alone.
    /// Waiting for the body would mean buffering whatever a hostile peer claimed
    /// to be sending.
    func testRejectsAnOversizedAnnouncedLengthWithoutBuffering() {
        var header = Data()
        var length = UInt32(LocalFraming.maxFrameBytes + 1).bigEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }

        var decoder = LocalFraming.Decoder()
        XCTAssertThrowsError(try decoder.append(header)) { error in
            XCTAssertEqual(
                error as? LocalFraming.Decoder.Failure,
                .frameTooLarge(announced: LocalFraming.maxFrameBytes + 1)
            )
        }
    }

    func testRejectsInvalidUTF8() {
        var frame = Data()
        var length = UInt32(2).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: [0xFF, 0xFE])

        var decoder = LocalFraming.Decoder()
        XCTAssertThrowsError(try decoder.append(frame)) { error in
            XCTAssertEqual(error as? LocalFraming.Decoder.Failure, .notUTF8)
        }
    }

    /// The cap matches the WebSocket transport's, so a message that is legal on
    /// one path cannot be illegal on the other.
    func testFrameCapMatchesTheSignalingEnvelopeCap() {
        XCTAssertEqual(LocalFraming.maxFrameBytes, SignalingEnvelope.maxMessageBytes)
    }
}
