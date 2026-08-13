import Foundation

/// Length-prefixed framing for the local-network signaling transport
/// (`docs/TASKS.md` Phase 5, "Local-network-only mode").
///
/// The WebSocket transport gets message boundaries for free. A raw TCP
/// connection does not: reads arrive in whatever chunks the network produces, so
/// two sealed envelopes can land in one read and one envelope can arrive split
/// across three. Every bug in a hand-rolled protocol of this kind is in that
/// reassembly, which is exactly why it lives here — as a pure value type with no
/// socket in sight — rather than inside a network callback.
///
/// The wire format is a 4-byte big-endian length followed by that many bytes of
/// UTF-8 JSON. The payload is the same sealed envelope the WebSocket carries, so
/// nothing above this layer knows or cares which transport it is on.
public enum LocalFraming {

    /// Same 16 KiB ceiling the server enforces on the WebSocket. Applied here
    /// too: without it a peer could announce a 4 GiB frame and the buffer would
    /// grow until the device died.
    public static let maxFrameBytes = SignalingEnvelope.maxMessageBytes

    /// Wraps one message for the wire.
    public static func encode(_ text: String) -> Data? {
        let body = Data(text.utf8)
        guard body.count <= maxFrameBytes else { return nil }
        var out = Data(capacity: body.count + 4)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    /// Accumulates bytes and hands back whole messages.
    ///
    /// Not thread-safe by design: it is owned by one connection's read loop and
    /// serialised by it. Sharing one across connections would interleave two
    /// byte streams into nonsense.
    public struct Decoder {

        /// Bytes received but not yet forming a complete frame.
        private var buffer = Data()

        public init() {}

        /// Why a stream had to be abandoned. Both cases are unrecoverable: the
        /// buffer is no longer aligned to a frame boundary, so there is nothing
        /// to resynchronise to.
        public enum Failure: Error, Equatable {
            /// A length prefix above `maxFrameBytes`.
            case frameTooLarge(announced: Int)
            /// A frame that was not valid UTF-8.
            case notUTF8
        }

        /// Appends `data` and returns every complete message it produced.
        public mutating func append(_ data: Data) throws -> [String] {
            buffer.append(data)
            var messages: [String] = []

            while true {
                guard buffer.count >= 4 else { break }

                let length = buffer.prefix(4).reduce(Int(0)) { ($0 << 8) | Int($1) }
                guard length <= LocalFraming.maxFrameBytes else {
                    throw Failure.frameTooLarge(announced: length)
                }
                // The body has not all arrived yet; wait for more bytes rather
                // than consuming a partial frame.
                guard buffer.count >= 4 + length else { break }

                let body = buffer.dropFirst(4).prefix(length)
                guard let text = String(data: Data(body), encoding: .utf8) else {
                    throw Failure.notUTF8
                }
                messages.append(text)
                buffer = Data(buffer.dropFirst(4 + length))
            }
            return messages
        }

        /// Bytes held pending more input. Exposed so a test can assert that a
        /// partial frame really is being retained rather than dropped.
        public var pendingByteCount: Int { buffer.count }
    }
}
