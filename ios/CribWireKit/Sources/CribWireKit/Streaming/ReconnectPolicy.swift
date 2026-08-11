import Foundation

/// Exponential backoff for reconnects (`ios-app.md` §3: 1 s → 30 s cap).
///
/// Pure arithmetic so the ladder can be asserted in a test instead of observed
/// by waiting: the engine asks for a delay, sleeps, and asks again.
public struct ReconnectPolicy: Equatable, Sendable {
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval
    public var multiplier: Double
    /// Fraction of the delay that jitter may add or remove. Without it, a
    /// household's Camera and Viewer that lost Wi-Fi at the same moment retry in
    /// lockstep for ever.
    public var jitterFraction: Double

    public init(
        initialDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 30,
        multiplier: Double = 2,
        jitterFraction: Double = 0.2
    ) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
        self.jitterFraction = jitterFraction
    }

    /// Delay before attempt `attempt` (1-based).
    ///
    /// - Parameter randomUnit: a value in `0...1`; injected rather than drawn
    ///   here so tests are deterministic. `0.5` means "no jitter".
    public func delay(forAttempt attempt: Int, randomUnit: Double = 0.5) -> TimeInterval {
        guard attempt >= 1 else { return 0 }
        let exponent = Double(attempt - 1)
        let base = min(initialDelay * pow(multiplier, exponent), maximumDelay)
        let clampedUnit = min(max(randomUnit, 0), 1)
        let jitter = (clampedUnit * 2 - 1) * jitterFraction * base
        return max(0, base + jitter)
    }
}

/// Why the streaming engine is trying to reconnect. Drives whether an ICE
/// restart is enough or the whole session has to be rebuilt.
public enum ReconnectTrigger: Equatable, Sendable {
    /// `NWPathMonitor` reported a different path (Wi-Fi → cellular).
    case networkPathChanged
    /// ICE said `disconnected` or `failed`.
    case iceFailure
    /// The signaling socket dropped.
    case signalingClosed

    /// An ICE restart keeps the DTLS session — and therefore the verified
    /// fingerprint — alive, so it is preferred wherever it can work
    /// (`ios-app.md` §3). A dead signaling socket has to be re-established
    /// first, because an ICE restart is itself signalled.
    public var prefersICERestart: Bool {
        switch self {
        case .networkPathChanged, .iceFailure:
            return true
        case .signalingClosed:
            return false
        }
    }
}
