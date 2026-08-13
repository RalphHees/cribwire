import Foundation

/// Stops a device signing two requests with the same timestamp.
///
/// The `CribWire-HMAC` MAC covers method, path, timestamp, principal and body
/// hash — and nothing else. For the signalling upgrade every one of those is
/// constant except the timestamp, which has **one-second granularity**, so two
/// upgrades by the same device in the same wall-clock second produce a byte-identical
/// MAC. The server's replay cache is keyed on exactly that MAC, so the second one
/// is refused as `replayed_request`, and the entry lives for twice the auth window
/// (120 s by default) — meaning that second stays unusable for two minutes.
///
/// That is precisely the shape of a reconnect: a socket drops, the ladder retries,
/// and an attempt lands on a second already spent. The connection then fails for a
/// reason that looks nothing like the cause — a 401, from a device holding a
/// perfectly good key.
///
/// The fix is to never offer the same second twice. The accepted clock skew is
/// symmetric (`|now − timestamp| ≤ windowSeconds`), so a timestamp a second or two
/// ahead is as valid as one exactly now, and no waiting is needed. Drift is bounded
/// by how fast reconnects are attempted, which the backoff ladder caps well inside
/// the window.
public struct RequestTimestampSequencer: Sendable {

    private var lastUsed: Int64?

    public init() {}

    /// The timestamp to sign with: `date`'s second, or one past the last one used,
    /// whichever is later.
    public mutating func next(after date: Date) -> Date {
        let candidate = Int64(date.timeIntervalSince1970.rounded(.down))
        let chosen: Int64
        if let lastUsed, candidate <= lastUsed {
            chosen = lastUsed + 1
        } else {
            chosen = candidate
        }
        lastUsed = chosen
        return Date(timeIntervalSince1970: TimeInterval(chosen))
    }

    /// How far ahead of `date` this sequencer has been pushed.
    ///
    /// A caller can use this to notice it is retrying so fast that it is
    /// approaching the server's skew window — which would be a bug in the retry
    /// ladder, not in the clock.
    public func drift(from date: Date) -> TimeInterval {
        guard let lastUsed else { return 0 }
        return max(0, TimeInterval(lastUsed) - date.timeIntervalSince1970)
    }
}
