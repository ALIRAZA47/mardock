import Foundation

/// The fisheye magnification used by the dock.
///
/// Rather than scaling icons and re-centering the row (which makes the icon
/// under the pointer drift away from it), the dock warps the axis itself.
/// Every point `u` of the un-magnified row is mapped to
///
///     X(u) = focus + ∫ from focus to u of s(w) dw
///
/// where `s` is the local scale: a raised-cosine bump peaking at the focus.
/// Because `X(focus) == focus`, whatever is under the pointer stays exactly
/// under it, and because `s ≥ 1`, the mapping is monotonic, so icons can
/// never overlap. The integral has a closed form, so this is cheap.
public struct Magnifier: Equatable, Sendable {
    /// Pointer position along the dock axis.
    public var focus: Double
    /// Scale at the focus (1 disables magnification).
    public var peakScale: Double
    /// Distance from the focus at which the scale falls back to 1.
    public var radius: Double

    public init(focus: Double, peakScale: Double, radius: Double) {
        self.focus = focus
        self.peakScale = max(1, peakScale)
        self.radius = max(radius, 1)
    }

    public static let identity = Magnifier(focus: 0, peakScale: 1, radius: 1)

    /// The local scale factor at an un-magnified coordinate.
    public func scale(at u: Double) -> Double {
        guard peakScale > 1 else { return 1 }
        let t = abs(u - focus) / radius
        guard t < 1 else { return 1 }
        return 1 + (peakScale - 1) * 0.5 * (1 + cos(Double.pi * t))
    }

    /// Maps an un-magnified coordinate to its magnified position.
    public func warp(_ u: Double) -> Double {
        guard peakScale > 1 else { return u }
        return u + (peakScale - 1) * Self.bumpIntegral(u - focus, radius: radius)
    }

    /// The most the row can grow on one side of the focus.
    public var maxGrowthPerSide: Double { (peakScale - 1) * radius / 2 }

    /// ∫ from 0 to d of ½(1 + cos(πw/r)) dw, clamped outside [-r, r].
    static func bumpIntegral(_ d: Double, radius r: Double) -> Double {
        if d >= r { return r / 2 }
        if d <= -r { return -r / 2 }
        return d / 2 + r / (2 * Double.pi) * sin(Double.pi * d / r)
    }
}
