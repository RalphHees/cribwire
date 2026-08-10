import Foundation

/// IEC 61672 A-weighting, as a cascade of three biquads.
///
/// `ios-app.md` §2.5 asks for "A-weighted RMS over 500 ms windows". A-weighting
/// is what makes the threshold mean something: unweighted RMS is dominated by
/// low-frequency rumble — traffic, a fan, the phone resting on a wooden shelf —
/// while a baby's cry sits where the ear (and this curve) is most sensitive.
///
/// The analog prototype is
///
/// ```
///           K · s⁴
/// H(s) = ─────────────────────────────────────
///        (s+ω₁)² (s+ω₂) (s+ω₃) (s+ω₄)²
/// ```
///
/// with the standard pole frequencies, split into `s²/(s+ω₁)²`, `s²/(s+ω₄)²` and
/// `1/((s+ω₂)(s+ω₃))`, each mapped to a digital biquad by the bilinear
/// transform. `K` is not applied analytically: the cascade is normalised
/// numerically to 0 dB at 1 kHz, which is the definition of the curve anyway and
/// avoids a magic constant nobody can check.
///
/// Accuracy of this (standard) design at 48 kHz, against the published table:
/// 31.5 Hz −39.5 (−39.4), 100 Hz −19.15 (−19.1), 1 kHz 0.00 (0), 4 kHz +0.93
/// (+1.0). Bilinear warping pulls the top octave down — −3.7 dB at 10 kHz where
/// the table says −2.5 — which is irrelevant here: nothing in a nursery is
/// judged on 10 kHz content, and the deviation makes the detector slightly
/// *less* likely to fire on hiss.
public struct AWeightingFilter: Equatable, Sendable {

    // Pole frequencies from the standard.
    private static let f1 = 20.598997
    private static let f2 = 107.65265
    private static let f3 = 737.86223
    private static let f4 = 12194.217

    /// The frequency the curve is normalised at.
    public static let referenceFrequency = 1000.0

    private struct Section: Equatable, Sendable {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double

        var x1: Double = 0
        var x2: Double = 0
        var y1: Double = 0
        var y2: Double = 0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
        }

        /// |H(e^{jω})| as a complex value, for the response tests and for the
        /// normalisation gain.
        func response(omega: Double) -> (re: Double, im: Double) {
            let c1 = cos(omega), s1 = sin(omega)
            let c2 = cos(2 * omega), s2 = sin(2 * omega)
            let nr = b0 + b1 * c1 + b2 * c2
            let ni = -(b1 * s1 + b2 * s2)
            let dr = 1 + a1 * c1 + a2 * c2
            let di = -(a1 * s1 + a2 * s2)
            let denominator = dr * dr + di * di
            guard denominator > 0 else { return (0, 0) }
            return (
                (nr * dr + ni * di) / denominator,
                (ni * dr - nr * di) / denominator
            )
        }
    }

    public let sampleRate: Double
    private var sections: [Section]
    private let gain: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let twoPi = 2 * Double.pi
        let w1 = twoPi * Self.f1
        let w2 = twoPi * Self.f2
        let w3 = twoPi * Self.f3
        let w4 = twoPi * Self.f4

        let designed = [
            // s² / (s + ω₁)²
            Self.bilinear(numerator: (1, 0, 0), denominator: (1, 2 * w1, w1 * w1), sampleRate: sampleRate),
            // s² / (s + ω₄)²
            Self.bilinear(numerator: (1, 0, 0), denominator: (1, 2 * w4, w4 * w4), sampleRate: sampleRate),
            // 1 / ((s + ω₂)(s + ω₃))
            Self.bilinear(numerator: (0, 0, 1), denominator: (1, w2 + w3, w2 * w3), sampleRate: sampleRate)
        ]
        self.sections = designed

        // Normalise to 0 dB at 1 kHz. Below a 2 kHz sample rate there is no
        // 1 kHz to normalise at; such a rate never reaches us from
        // AVAudioEngine, and falling back to unity is better than dividing by
        // something meaningless.
        let magnitude = Self.magnitude(of: designed, frequency: Self.referenceFrequency, sampleRate: sampleRate)
        self.gain = (sampleRate > 2 * Self.referenceFrequency && magnitude > 0) ? 1 / magnitude : 1
    }

    // MARK: - Design

    /// Bilinear transform of one analog section, coefficients ordered
    /// `(s², s¹, s⁰)`.
    private static func bilinear(
        numerator: (Double, Double, Double),
        denominator: (Double, Double, Double),
        sampleRate: Double
    ) -> Section {
        let c = 2 * sampleRate
        let c2 = c * c
        let (b2, b1, b0) = numerator
        let (a2, a1, a0) = denominator

        let nb0 = b2 * c2 + b1 * c + b0
        let nb1 = -2 * b2 * c2 + 2 * b0
        let nb2 = b2 * c2 - b1 * c + b0
        let na0 = a2 * c2 + a1 * c + a0
        let na1 = -2 * a2 * c2 + 2 * a0
        let na2 = a2 * c2 - a1 * c + a0

        return Section(
            b0: nb0 / na0,
            b1: nb1 / na0,
            b2: nb2 / na0,
            a1: na1 / na0,
            a2: na2 / na0
        )
    }

    private static func magnitude(
        of sections: [Section],
        frequency: Double,
        sampleRate: Double
    ) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        var re = 1.0
        var im = 0.0
        for section in sections {
            let h = section.response(omega: omega)
            let nextRe = re * h.re - im * h.im
            im = re * h.im + im * h.re
            re = nextRe
        }
        return (re * re + im * im).squareRoot()
    }

    // MARK: - Use

    /// Gain of the whole weighted chain at `frequency`, in dB relative to 1 kHz.
    /// Used by the tests to check the curve against the published table.
    public func responseDB(atFrequency frequency: Double) -> Double {
        let magnitude = Self.magnitude(of: sections, frequency: frequency, sampleRate: sampleRate) * gain
        guard magnitude > 0 else { return -.infinity }
        return 20 * log10(magnitude)
    }

    /// Filters one block, carrying state across calls, and returns the weighted
    /// samples.
    public mutating func process(_ samples: [Float]) -> [Double] {
        var output = [Double]()
        output.reserveCapacity(samples.count)
        for sample in samples {
            var value = Double(sample) * gain
            for index in sections.indices {
                value = sections[index].process(value)
            }
            output.append(value)
        }
        return output
    }

    /// Filters one block and returns its level.
    ///
    /// The scale is dBFS **referred to a full-scale sine**: a ±1.0 sine reads
    /// 0 dBFS, which is what makes the presets in `ios-app.md` §2.5 (−20 / −30 /
    /// −40 dBFS) read the way a level meter does. Silence returns
    /// ``AWeightingFilter/silenceFloorDB`` rather than −∞ so the value can go
    /// straight into a UI meter.
    public mutating func levelDBFS(of samples: [Float]) -> Double {
        guard !samples.isEmpty else { return Self.silenceFloorDB }
        let weighted = process(samples)
        var sumOfSquares = 0.0
        for value in weighted {
            sumOfSquares += value * value
        }
        let rms = (sumOfSquares / Double(weighted.count)).squareRoot()
        return Self.decibels(fromRMS: rms)
    }

    /// Lowest level reported, in dB. Deep enough to be below any real room and
    /// shallow enough to keep a meter's animation sane.
    public static let silenceFloorDB = -100.0

    /// RMS → dBFS with the full-scale-sine reference described above.
    public static func decibels(fromRMS rms: Double) -> Double {
        let referenced = rms * 2.0.squareRoot()
        guard referenced > 0 else { return silenceFloorDB }
        return max(silenceFloorDB, 20 * log10(referenced))
    }

    /// Drops the filter state — used when capture restarts after an
    /// interruption, so a discontinuity does not ring through the filter and
    /// look like a noise event.
    public mutating func reset() {
        for index in sections.indices {
            sections[index].x1 = 0
            sections[index].x2 = 0
            sections[index].y1 = 0
            sections[index].y2 = 0
        }
    }
}
