import Foundation

public enum ThemeID: String, Codable, CaseIterable, Sendable, Identifiable {
    case glass
    case liquid
    case aurora
    case midnight
    case sunset
    case mirror
    case minimal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .glass: return "Glass"
        case .liquid: return "Liquid"
        case .aurora: return "Aurora"
        case .midnight: return "Midnight"
        case .sunset: return "Sunset"
        case .mirror: return "Mirror"
        case .minimal: return "Minimal"
        }
    }

    public var tagline: String {
        switch self {
        case .glass: return "Frosted glass that adapts to light and dark."
        case .liquid: return "Clear, refractive glass with a moving highlight."
        case .aurora: return "Slow ribbons of colour drifting under smoked glass."
        case .midnight: return "Deep smoke with a neon edge."
        case .sunset: return "Warm glass, tinted like golden hour."
        case .mirror: return "A glossy floor with reflections, for the classicists."
        case .minimal: return "No shelf. Just your icons, floating."
        }
    }
}

public enum DockPosition: String, Codable, CaseIterable, Sendable, Identifiable {
    case bottom
    case left
    case right

    public var id: String { rawValue }
    public var isVertical: Bool { self != .bottom }
}

public enum DisplayPreference: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The display with the menu bar.
    case main
    /// Moves to whichever display the pointer pushes against the dock edge.
    case followMouse

    public var id: String { rawValue }
}

public enum IndicatorStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case glow
    case dot
    case line
    case none

    public var id: String { rawValue }
}

public enum AccentChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Whatever the theme prefers.
    case theme
    /// The macOS accent colour.
    case system
    case blue, purple, pink, red, orange, yellow, green, teal, graphite

    public var id: String { rawValue }
}

/// The modifier keys that, with 1–9, open the dock's first nine apps.
public enum LaunchShortcut: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    case controlOption
    case option
    case commandOption

    public var id: String { rawValue }

    /// How menus write the modifiers, e.g. "⌃⌥".
    public var symbols: String {
        switch self {
        case .off: return ""
        case .controlOption: return "⌃⌥"
        case .option: return "⌥"
        case .commandOption: return "⌥⌘"
        }
    }
}

/// Every user preference. Decoding never fails: unknown or missing keys fall
/// back to defaults and every number is clamped to its allowed range, so a
/// damaged or tampered preferences file can't put the app in a bad state.
public struct DockSettings: Codable, Equatable, Sendable {
    public var theme: ThemeID = .glass
    /// A theme the user made (`theme:…`), used instead of `theme` while it exists.
    public var customTheme: String?
    public var accent: AccentChoice = .theme
    public var iconSize: Double = 56
    public var magnificationEnabled = true
    public var magnification: Double = 1.8
    public var magnificationSpread: Double = 3
    public var position: DockPosition = .bottom
    public var display: DisplayPreference = .main
    public var autoHide: AutoHideMode = .off
    public var revealDelay: Double = 0.12
    public var showLabels = true
    public var showRunningApps = true
    public var showTrash = true
    public var clickToHide = false
    public var bounceOnLaunch = true
    public var clickRipple = true
    public var reflections = false
    public var indicatorStyle: IndicatorStyle = .glow
    public var dimHiddenApps = true
    public var animationSpeed: Double = 1
    public var hideSystemDock = false
    public var restoreSystemDockOnQuit = true
    public var showInFullScreen = false
    public var launchShortcut: LaunchShortcut = .controlOption
    public var showRecentApps = true
    public var recentAppsCount = 3
    // Extras that need a permission, all off until the user turns them on.
    /// Badges such as unread counts, read from the macOS Dock (Accessibility).
    public var showBadges = false
    /// Minimized windows as tiles next to the Trash (Accessibility).
    public var showMinimizedWindows = false
    /// Pictures of an app's windows while hovering its tile (Screen Recording).
    public var windowPreviews = false
    /// A full Trash icon while the Trash has something in it.
    public var showTrashFull = false

    public static let iconSizeRange: ClosedRange<Double> = 32...112
    public static let magnificationRange: ClosedRange<Double> = 1.1...2.6
    public static let spreadRange: ClosedRange<Double> = 1.5...6
    public static let revealDelayRange: ClosedRange<Double> = 0...1.5
    public static let animationSpeedRange: ClosedRange<Double> = 0.5...2
    public static let recentAppsRange: ClosedRange<Int> = 1...10

    public init() {}

    /// A copy with every number clamped and every non-finite value replaced.
    public func sanitized() -> DockSettings {
        var s = self
        let d = DockSettings.defaults
        s.iconSize = Self.clamp(iconSize, Self.iconSizeRange, fallback: d.iconSize)
        s.magnification = Self.clamp(magnification, Self.magnificationRange, fallback: d.magnification)
        s.magnificationSpread = Self.clamp(magnificationSpread, Self.spreadRange, fallback: d.magnificationSpread)
        s.revealDelay = Self.clamp(revealDelay, Self.revealDelayRange, fallback: d.revealDelay)
        s.animationSpeed = Self.clamp(animationSpeed, Self.animationSpeedRange, fallback: d.animationSpeed)
        s.recentAppsCount = min(max(recentAppsCount, Self.recentAppsRange.lowerBound), Self.recentAppsRange.upperBound)
        if let custom = customTheme, custom.hasPrefix("builtin:") || !ThemeRecipe.isValidID(custom) {
            s.customTheme = nil
        }
        return s
    }

    /// The settings to use after importing a settings file: everything in it
    /// except the choices that belong to this Mac (the macOS Dock, which
    /// display) and the extras, which only Settings turns on — so a file can
    /// never switch on something that uses a permission given here.
    public func importing(_ imported: DockSettings) -> DockSettings {
        var s = imported
        s.hideSystemDock = hideSystemDock
        s.restoreSystemDockOnQuit = restoreSystemDockOnQuit
        s.display = display
        s.showBadges = showBadges
        s.showMinimizedWindows = showMinimizedWindows
        s.windowPreviews = windowPreviews
        s.showTrashFull = showTrashFull
        return s.sanitized()
    }

    public static let defaults = DockSettings()

    static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case theme, customTheme, accent, iconSize, magnificationEnabled, magnification, magnificationSpread
        case position, display, autoHide, revealDelay, showLabels, showRunningApps, showTrash
        case clickToHide, bounceOnLaunch, clickRipple, reflections, indicatorStyle, dimHiddenApps
        case animationSpeed, hideSystemDock, restoreSystemDockOnQuit, showInFullScreen
        case launchShortcut, showRecentApps, recentAppsCount
        case showBadges, showMinimizedWindows, windowPreviews, showTrashFull
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = DockSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        s.theme = value(.theme, s.theme)
        s.customTheme = value(.customTheme, s.customTheme)
        s.accent = value(.accent, s.accent)
        s.iconSize = value(.iconSize, s.iconSize)
        s.magnificationEnabled = value(.magnificationEnabled, s.magnificationEnabled)
        s.magnification = value(.magnification, s.magnification)
        s.magnificationSpread = value(.magnificationSpread, s.magnificationSpread)
        s.position = value(.position, s.position)
        s.display = value(.display, s.display)
        s.autoHide = value(.autoHide, s.autoHide)
        s.revealDelay = value(.revealDelay, s.revealDelay)
        s.showLabels = value(.showLabels, s.showLabels)
        s.showRunningApps = value(.showRunningApps, s.showRunningApps)
        s.showTrash = value(.showTrash, s.showTrash)
        s.clickToHide = value(.clickToHide, s.clickToHide)
        s.bounceOnLaunch = value(.bounceOnLaunch, s.bounceOnLaunch)
        s.clickRipple = value(.clickRipple, s.clickRipple)
        s.reflections = value(.reflections, s.reflections)
        s.indicatorStyle = value(.indicatorStyle, s.indicatorStyle)
        s.dimHiddenApps = value(.dimHiddenApps, s.dimHiddenApps)
        s.animationSpeed = value(.animationSpeed, s.animationSpeed)
        s.hideSystemDock = value(.hideSystemDock, s.hideSystemDock)
        s.restoreSystemDockOnQuit = value(.restoreSystemDockOnQuit, s.restoreSystemDockOnQuit)
        s.showInFullScreen = value(.showInFullScreen, s.showInFullScreen)
        s.launchShortcut = value(.launchShortcut, s.launchShortcut)
        s.showRecentApps = value(.showRecentApps, s.showRecentApps)
        s.recentAppsCount = value(.recentAppsCount, s.recentAppsCount)
        s.showBadges = value(.showBadges, s.showBadges)
        s.showMinimizedWindows = value(.showMinimizedWindows, s.showMinimizedWindows)
        s.windowPreviews = value(.windowPreviews, s.windowPreviews)
        s.showTrashFull = value(.showTrashFull, s.showTrashFull)
        self = s.sanitized()
    }

    /// Decodes stored settings, refusing oversized blobs.
    public static func decode(_ data: Data?) -> DockSettings {
        guard let data, data.count <= 64 * 1024,
              let settings = try? JSONDecoder().decode(DockSettings.self, from: data)
        else { return DockSettings() }
        return settings
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(sanitized())
    }
}
