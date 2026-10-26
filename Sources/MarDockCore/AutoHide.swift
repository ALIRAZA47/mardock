import Foundation

public enum AutoHideMode: String, Codable, CaseIterable, Sendable {
    /// The dock is always visible.
    case off
    /// The dock hides until the pointer touches the screen edge.
    case always
    /// The dock only hides while the frontmost app's window would overlap it.
    case smart
}

/// The auto-hide state machine. Pure and clock-driven so it can be tested.
public struct AutoHideLogic: Equatable, Sendable {
    public struct Inputs: Equatable, Sendable {
        public var now: Double
        /// The pointer is pressed against the dock's screen edge.
        public var pointerAtEdge: Bool
        /// The pointer is over the visible dock.
        public var pointerInDock: Bool
        /// A window of the frontmost app overlaps the dock (smart mode).
        public var windowOverlaps: Bool
        /// Something needs the dock to stay put (a drag, an open menu…).
        public var holdOpen: Bool

        public init(now: Double, pointerAtEdge: Bool = false, pointerInDock: Bool = false, windowOverlaps: Bool = false, holdOpen: Bool = false) {
            self.now = now
            self.pointerAtEdge = pointerAtEdge
            self.pointerInDock = pointerInDock
            self.windowOverlaps = windowOverlaps
            self.holdOpen = holdOpen
        }
    }

    public var mode: AutoHideMode
    /// How long the pointer must rest at the edge before the dock appears.
    public var revealDelay: Double
    /// How long after the pointer leaves before the dock hides.
    public var hideDelay: Double
    public private(set) var isShown = true
    private var edgeSince: Double?
    private var leftSince: Double?

    public init(mode: AutoHideMode = .off, revealDelay: Double = 0.12, hideDelay: Double = 0.45) {
        self.mode = mode
        self.revealDelay = revealDelay
        self.hideDelay = hideDelay
    }

    /// True while a timer must keep calling `update` (a transition is pending).
    public var hasPendingTransition: Bool { edgeSince != nil || leftSince != nil }

    /// Feeds the current inputs and returns whether the dock should be shown.
    @discardableResult
    public mutating func update(_ input: Inputs) -> Bool {
        let wantsHiding: Bool
        switch mode {
        case .off: wantsHiding = false
        case .always: wantsHiding = true
        case .smart: wantsHiding = input.windowOverlaps
        }

        guard wantsHiding, !input.holdOpen else {
            isShown = true
            edgeSince = nil
            leftSince = nil
            return true
        }

        if isShown {
            edgeSince = nil
            if input.pointerInDock || input.pointerAtEdge {
                leftSince = nil
            } else {
                let since = leftSince ?? input.now
                leftSince = since
                if input.now - since >= hideDelay {
                    isShown = false
                    leftSince = nil
                }
            }
        } else {
            leftSince = nil
            if input.pointerAtEdge {
                let since = edgeSince ?? input.now
                edgeSince = since
                if input.now - since >= revealDelay {
                    isShown = true
                    edgeSince = nil
                }
            } else {
                edgeSince = nil
            }
        }
        return isShown
    }
}
