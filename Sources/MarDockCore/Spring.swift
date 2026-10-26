import Foundation

/// A damped harmonic oscillator with unit mass.
///
/// The spring is advanced with the closed-form solution of the oscillator
/// rather than by numerical integration, so it is stable for any frame time:
/// a long hitch, a display waking from sleep or a 240 Hz panel all produce
/// the same motion.
///
/// It is parameterised like SwiftUI's springs: `response` is the period of the
/// undamped oscillation in seconds and `dampingFraction` is the damping ratio
/// (1 = critically damped, below 1 overshoots).
public struct Spring: Equatable, Sendable {
    public var value: Double
    public var velocity: Double
    public var target: Double
    public var response: Double
    public var dampingFraction: Double
    /// Once both the distance to the target and the speed fall below this
    /// (speed is compared against ten times the value) the spring snaps to rest.
    public var precision: Double

    public init(
        _ value: Double,
        response: Double = 0.3,
        dampingFraction: Double = 0.86,
        precision: Double = 0.001
    ) {
        self.value = value
        self.velocity = 0
        self.target = value
        self.response = response
        self.dampingFraction = dampingFraction
        self.precision = precision
    }

    public var isAtRest: Bool { value == target && velocity == 0 }

    /// Jumps straight to `newValue` with no motion.
    public mutating func snap(to newValue: Double) {
        value = newValue
        target = newValue
        velocity = 0
    }

    /// Advances the simulation by `dt` seconds.
    public mutating func step(_ dt: Double) {
        guard dt > 0, !isAtRest else { return }
        guard value.isFinite, velocity.isFinite, target.isFinite else {
            snap(to: target.isFinite ? target : 0)
            return
        }

        let dt = min(dt, 1)
        let omega = 2 * Double.pi / max(response, 1e-4)
        let zeta = max(dampingFraction, 0)
        let x0 = value - target
        let v0 = velocity
        let x: Double
        let v: Double

        if zeta < 0.999 {
            // Under-damped: decaying sinusoid.
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega * dt)
            let a = x0
            let b = (v0 + zeta * omega * x0) / wd
            let c = cos(wd * dt)
            let s = sin(wd * dt)
            x = decay * (a * c + b * s)
            v = decay * ((b * wd - zeta * omega * a) * c - (a * wd + zeta * omega * b) * s)
        } else if zeta <= 1.001 {
            // Critically damped.
            let decay = exp(-omega * dt)
            let b = v0 + omega * x0
            x = (x0 + b * dt) * decay
            v = (b - omega * (x0 + b * dt)) * decay
        } else {
            // Over-damped: sum of two decaying exponentials.
            let root = (zeta * zeta - 1).squareRoot()
            let r1 = -omega * (zeta - root)
            let r2 = -omega * (zeta + root)
            let c2 = (v0 - r1 * x0) / (r2 - r1)
            let c1 = x0 - c2
            let e1 = exp(r1 * dt)
            let e2 = exp(r2 * dt)
            x = c1 * e1 + c2 * e2
            v = c1 * r1 * e1 + c2 * r2 * e2
        }

        if abs(x) < precision && abs(v) < precision * 10 {
            value = target
            velocity = 0
        } else {
            value = target + x
            velocity = v
        }
    }
}
