import Foundation

/// The launch "hop": a ballistic arc with a little squash-and-stretch.
public enum BounceCurve {
    public static let period: Double = 0.62

    public struct Sample: Equatable, Sendable {
        /// Height above the resting position, as a fraction of the bounce height.
        public var height: Double
        /// Scale along the dock axis (wider when squashed).
        public var mainScale: Double
        /// Scale away from the screen edge (shorter when squashed).
        public var crossScale: Double

        public static let rest = Sample(height: 0, mainScale: 1, crossScale: 1)
    }

    /// Samples the bounce `elapsed` seconds after it started.
    public static func sample(elapsed: Double, period: Double = period) -> Sample {
        guard elapsed > 0, period > 0 else { return .rest }
        let phase = elapsed / period
        let p = phase - phase.rounded(.down)
        // Parabola: 0 at take-off and landing, 1 at the apex.
        let height = 4 * p * (1 - p)
        // Squash for the first and last 10% of each hop (around contact)...
        let contact = max(0, 1 - min(p, 1 - p) / 0.1)
        // ...and stretch a little on the way up and down.
        let stretch = max(0, 1 - abs(p - 0.5) / 0.5) * (1 - contact)
        let crossScale = 1 - 0.12 * contact + 0.05 * stretch * (1 - height)
        let mainScale = 1 + 0.10 * contact - 0.03 * stretch * (1 - height)
        return Sample(height: height, mainScale: mainScale, crossScale: crossScale)
    }

    /// When a bounce that started at `start` should stop if asked to stop at
    /// `request`: at the end of the current hop, and never before one full hop.
    public static func stopTime(start: Double, request: Double, period: Double = period) -> Double {
        let elapsed = max(0, request - start)
        let hops = max(1, (elapsed / period).rounded(.up))
        return start + hops * period
    }
}
