import Foundation

/// Geometry of the dock, in points.
///
/// Positions use two axes that are independent of where the dock sits:
/// `u` runs along the dock (left→right for a bottom dock, top→bottom for a
/// side dock) and `v` runs away from the screen edge into the screen.
public struct DockMetrics: Equatable, Sendable {
    public var iconSize: Double
    /// Gap between neighbouring icons.
    public var spacing: Double
    /// Configured magnification (1 = off).
    public var peakScale: Double
    /// How far magnification reaches, measured in icon slots.
    public var spread: Double
    /// Shelf padding beyond the first and last icon.
    public var endPadding: Double
    /// Distance between the screen edge and the shelf.
    public var edgeGap: Double
    /// Shelf padding on the screen-edge side (the running indicators live here).
    public var insetBottom: Double
    /// Shelf padding on the far side of the icons.
    public var insetTop: Double
    /// Width of the slot a separator occupies.
    public var separatorWidth: Double

    public init(
        iconSize: Double = 56,
        spacing: Double = 8,
        peakScale: Double = 1.8,
        spread: Double = 3,
        endPadding: Double = 9,
        edgeGap: Double = 6,
        insetBottom: Double = 9,
        insetTop: Double = 7,
        separatorWidth: Double = 18
    ) {
        self.iconSize = iconSize
        self.spacing = spacing
        self.peakScale = peakScale
        self.spread = spread
        self.endPadding = endPadding
        self.edgeGap = edgeGap
        self.insetBottom = insetBottom
        self.insetTop = insetTop
        self.separatorWidth = separatorWidth
    }

    /// Metrics derived from user settings. `tallFloor` gives the shelf extra
    /// room below the icons (used by the reflective "Mirror" theme).
    public static func make(from settings: DockSettings, tallFloor: Bool = false, iconSize override: Double? = nil) -> DockMetrics {
        let s = settings.sanitized()
        let requested = override ?? s.iconSize
        let icon = requested.isFinite ? min(max(requested, 16), DockSettings.iconSizeRange.upperBound) : s.iconSize
        return DockMetrics(
            iconSize: icon,
            spacing: max(5, (icon * 0.15).rounded()),
            peakScale: s.magnificationEnabled ? s.magnification : 1,
            spread: s.magnificationSpread,
            endPadding: max(8, (icon * 0.17).rounded()),
            edgeGap: 6,
            insetBottom: tallFloor ? max(14, (icon * 0.32).rounded()) : max(8, (icon * 0.17).rounded()),
            insetTop: max(6, (icon * 0.12).rounded()),
            separatorWidth: max(14, (icon * 0.34).rounded())
        )
    }

    /// Metrics that fit `tiles` icons and `separators` dividers into
    /// `available` points, magnified or not, shrinking the icons (like the
    /// macOS Dock does) if the preferred size doesn't fit. Never grows them.
    public static func fitting(
        _ settings: DockSettings,
        tallFloor: Bool = false,
        tiles: Int,
        separators: Int,
        available: Double
    ) -> DockMetrics {
        var metrics = make(from: settings, tallFloor: tallFloor)
        guard available > 0, tiles + separators > 0 else { return metrics }
        for _ in 0..<12 {
            // Room for magnification too, so the magnified dock never runs
            // off the screen: centred at rest, it grows by at most
            // `maxGrowthPerSide` past each end.
            let needed = Double(tiles) * metrics.slot + Double(separators) * metrics.separatorWidth
                + 2 * metrics.endPadding + 2 * metrics.maxGrowthPerSide
            guard needed > available, metrics.iconSize > 16 else { break }
            let smaller = max(16, (metrics.iconSize * available / needed).rounded(.down))
            if smaller >= metrics.iconSize { break }
            metrics = make(from: settings, tallFloor: tallFloor, iconSize: smaller)
        }
        return metrics
    }

    public var slot: Double { iconSize + spacing }
    /// The most magnification lengthens the dock on one side of the pointer
    /// (the same as `Magnifier.maxGrowthPerSide` at full magnification).
    public var maxGrowthPerSide: Double { (max(peakScale, 1) - 1) * radius / 2 }
    public var shelfThickness: Double { insetBottom + iconSize + insetTop }
    public var radius: Double { max(slot * spread, slot) }
    public var bounceHeight: Double { (iconSize * 0.55).rounded() }
    /// Room reserved past the tallest icon for the hover label.
    public var labelRoom: Double { 44 }

    /// How deep (along `v`) the dock window must be to never clip anything.
    public var requiredDepth: Double {
        edgeGap + insetBottom + iconSize * max(peakScale, 1) + bounceHeight + labelRoom
    }

    /// How far the shelf travels to hide off-screen.
    public var hideDistance: Double { edgeGap + shelfThickness + 24 }
}
