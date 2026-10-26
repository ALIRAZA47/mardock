import Foundation

public enum DockItemKind: String, Equatable, Sendable {
    case app
    case separator
    case trash
}

/// What the dock should show for one tile. The engine turns a list of these
/// into animated geometry.
public struct DockItemSpec: Equatable, Sendable {
    public var id: String
    public var kind: DockItemKind
    public var isRunning: Bool
    public var isActive: Bool
    public var isHidden: Bool
    public var isLaunching: Bool

    public init(
        id: String,
        kind: DockItemKind = .app,
        isRunning: Bool = false,
        isActive: Bool = false,
        isHidden: Bool = false,
        isLaunching: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.isRunning = isRunning
        self.isActive = isActive
        self.isHidden = isHidden
        self.isLaunching = isLaunching
    }
}

/// Pointer position in dock coordinates (see `DockMetrics`).
public struct DockPointer: Equatable, Sendable {
    public var u: Double
    public var v: Double

    public init(u: Double, v: Double) {
        self.u = u
        self.v = v
    }
}

/// One laid-out, animated frame of the dock. Renderers draw exactly this.
public struct DockFrame: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var id: String
        public var kind: DockItemKind
        /// Icon centre along the dock.
        public var center: Double
        /// Icon edge length (before squash and press).
        public var size: Double
        public var slotStart: Double
        public var slotEnd: Double
        /// `v` of the icon's screen-edge side when resting.
        public var baseline: Double
        /// Extra `v` from bouncing and hovering.
        public var lift: Double
        /// Scale along the dock axis (squash, press).
        public var mainScale: Double
        /// Scale away from the screen edge (squash, press).
        public var crossScale: Double
        public var alpha: Double
        /// 0…1 visibility of the running indicator.
        public var indicator: Double
        /// 0…1 emphasis for the frontmost app.
        public var activeness: Double
        /// 0…1 glow while something is dragged over the tile.
        public var highlight: Double
        /// False while the tile is animating out.
        public var isLive: Bool

        /// Far edge of the icon along `v`, including bounce, hover and scale.
        public var top: Double { baseline + lift + size * crossScale }
    }

    public struct Label: Equatable, Sendable {
        public var id: String
        /// Anchor: centre of the icon along the dock...
        public var u: Double
        /// ...and just past its far edge.
        public var v: Double
        public var alpha: Double
    }

    public var items: [Item]
    public var shelfStart: Double
    public var shelfEnd: Double
    /// `v` of the shelf's screen-edge side (negative while hidden).
    public var shelfBaseline: Double
    public var shelfThickness: Double
    /// Overall opacity (fades out while hiding).
    public var opacity: Double
    /// 0 = hidden, 1 = shown.
    public var reveal: Double
    public var hoveredID: String?
    public var label: Label?
    public var focus: Double
    /// 0…1 progress of the magnification.
    public var magnification: Double
    public var pointer: DockPointer?

    public init(
        items: [Item] = [],
        shelfStart: Double = 0,
        shelfEnd: Double = 0,
        shelfBaseline: Double = 0,
        shelfThickness: Double = 0,
        opacity: Double = 1,
        reveal: Double = 1,
        hoveredID: String? = nil,
        label: Label? = nil,
        focus: Double = 0,
        magnification: Double = 0,
        pointer: DockPointer? = nil
    ) {
        self.items = items
        self.shelfStart = shelfStart
        self.shelfEnd = shelfEnd
        self.shelfBaseline = shelfBaseline
        self.shelfThickness = shelfThickness
        self.opacity = opacity
        self.reveal = reveal
        self.hoveredID = hoveredID
        self.label = label
        self.focus = focus
        self.magnification = magnification
        self.pointer = pointer
    }

    public var shelfLength: Double { shelfEnd - shelfStart }
    public var shelfTop: Double { shelfBaseline + shelfThickness }

    /// The tile under a point, if any. Separators are never hit.
    public func item(atU u: Double, v: Double, slop: Double = 4) -> Item? {
        guard v >= -slop else { return nil }
        for item in items where item.isLive && item.kind != .separator {
            guard u >= item.slotStart, u < item.slotEnd else { continue }
            let reach = max(item.top, shelfTop) + slop
            return v <= reach ? item : nil
        }
        return nil
    }

    /// Whether a point is over the dock: the shelf or any (magnified) icon.
    public func contains(u: Double, v: Double, slop: Double = 0) -> Bool {
        guard v >= -slop else { return false }
        if u >= shelfStart - slop, u <= shelfEnd + slop, v <= shelfTop + slop, shelfTop > 0 {
            return true
        }
        for item in items where item.isLive && u >= item.slotStart - slop && u <= item.slotEnd + slop {
            if v <= item.top + slop && item.top > 0 { return true }
        }
        return false
    }

    /// How many of `candidates` (by id, in order) have their centre before `u`.
    /// Used to pick where a dragged tile would land.
    public func insertionIndex(u: Double, among candidates: [String]) -> Int {
        let centers = Dictionary(items.filter(\.isLive).map { ($0.id, $0.center) }, uniquingKeysWith: { a, _ in a })
        var index = 0
        for id in candidates {
            guard let c = centers[id] else { continue }
            if c < u { index += 1 }
        }
        return index
    }

    public func item(id: String) -> Item? {
        items.first { $0.id == id && $0.isLive }
    }
}
