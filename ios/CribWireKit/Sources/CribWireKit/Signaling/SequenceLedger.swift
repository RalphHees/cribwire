import Foundation

/// Accept/reject decision for one inbound sequence number.
public enum SequenceDecision: Equatable, Sendable {
    case accept
    /// Exactly the sequence number we already processed — a replay.
    case replay
    /// Older than the last one accepted: either a reordered message or an
    /// attempt to rewind the stream. Both are rejected; signaling is small
    /// enough that re-sending is cheaper than tolerating gaps in order.
    case outOfOrder
    /// Not a sequence number at all (zero or negative).
    case malformed
}

/// Monotonic sequence check for one sender (`security.md` §4).
///
/// Strictly increasing, starting at 1. Gaps are allowed — the server may drop a
/// message and the peer will resend a later one — but going backwards or
/// repeating never is.
public struct SequenceGuard: Equatable, Sendable {
    public private(set) var lastAccepted: Int?

    public init(lastAccepted: Int? = nil) {
        self.lastAccepted = lastAccepted
    }

    /// Decides on `seq` and, when accepted, advances the watermark.
    public mutating func admit(_ seq: Int) -> SequenceDecision {
        guard seq >= 1 else { return .malformed }
        guard let lastAccepted else {
            self.lastAccepted = seq
            return .accept
        }
        if seq == lastAccepted { return .replay }
        if seq < lastAccepted { return .outOfOrder }
        self.lastAccepted = seq
        return .accept
    }
}

/// One `SequenceGuard` per authenticated sender.
///
/// A Camera can hold up to five Viewers (`ios-app.md` §2.2) and each of them
/// numbers its own messages from 1, so a single counter would reject the second
/// Viewer's first message. The key is the `from` field *inside* the sealed
/// payload — the server cannot set it, which is the whole point; a routing field
/// would let a malicious server split one peer's stream into two ledgers and
/// re-open the replay window it is supposed to close.
public struct SequenceLedger: Equatable, Sendable {
    /// Used when a peer sends no `from` (single-peer setups and older builds).
    public static let anonymousSender = "-"

    private var guards: [String: SequenceGuard] = [:]

    public init() {}

    public mutating func admit(_ seq: Int, from sender: String?) -> SequenceDecision {
        let key = sender.flatMap { $0.isEmpty ? nil : $0 } ?? Self.anonymousSender
        var senderGuard = guards[key] ?? SequenceGuard()
        let decision = senderGuard.admit(seq)
        guards[key] = senderGuard
        return decision
    }

    /// Forgets a sender — used when a Viewer goes offline, so that the same
    /// device restarting at `seq = 1` is not mistaken for a replay.
    ///
    /// This is safe precisely because a returning peer must still seal its
    /// messages under `K_sig`: forgetting a watermark lets an honest peer
    /// restart, it does not let anyone replay a captured blob against a
    /// *running* session.
    public mutating func forget(sender: String?) {
        guards.removeValue(forKey: sender ?? Self.anonymousSender)
    }

    public mutating func reset() {
        guards.removeAll()
    }

    public func lastAccepted(from sender: String?) -> Int? {
        guards[sender ?? Self.anonymousSender]?.lastAccepted
    }
}
