import Foundation

/// Converts between dock coordinates (`u` along the dock, `v` away from the
/// screen edge) and the coordinates of a bottom-left-origin view that spans
/// the dock's whole screen edge.
public struct DockAxis: Equatable, Sendable {
    public var position: DockPosition
    public var width: Double
    public var height: Double

    public init(position: DockPosition, width: Double, height: Double) {
        self.position = position
        self.width = width
        self.height = height
    }

    /// Length of the screen edge the dock runs along.
    public var length: Double { position.isVertical ? height : width }

    public func toDock(x: Double, y: Double) -> DockPointer {
        switch position {
        case .bottom: return DockPointer(u: x, v: y)
        case .left: return DockPointer(u: height - y, v: x)
        case .right: return DockPointer(u: height - y, v: width - x)
        }
    }

    public func toView(u: Double, v: Double) -> (x: Double, y: Double) {
        switch position {
        case .bottom: return (u, v)
        case .left: return (v, height - u)
        case .right: return (width - v, height - u)
        }
    }

    /// The view rectangle covering `u0…u1` along the dock and `v0…v1` across it.
    public func rect(u0: Double, u1: Double, v0: Double, v1: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let a = toView(u: u0, v: v0)
        let b = toView(u: u1, v: v1)
        return (min(a.x, b.x), min(a.y, b.y), abs(b.x - a.x), abs(b.y - a.y))
    }
}
