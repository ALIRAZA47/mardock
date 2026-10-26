import AppKit
import MarDockCore

/// Everything a theme decides about how the dock looks. Themes are pure data;
/// `DockView` turns them into layers.
struct ThemeStyle {
    enum Backdrop {
        /// Frosted glass blurred from whatever is behind the dock.
        case material(NSVisualEffectView.Material)
        /// macOS 26 Liquid Glass where available, otherwise the given material.
        case liquidGlass(fallback: NSVisualEffectView.Material)
        /// No glass at all.
        case none
    }

    var backdrop: Backdrop
    /// Forces the glass (and label) into light or dark.
    var appearance: NSAppearance.Name?
    var tintColors: [NSColor] = []
    var tintOpacity: Float = 0
    var auroraColors: [NSColor] = []
    var auroraOpacity: Float = 0
    /// Soft light along the inner edge of the glass.
    var innerHighlight: Float = 0.18
    var borderStart: NSColor = .white.withAlphaComponent(0.5)
    var borderEnd: NSColor = .white.withAlphaComponent(0.1)
    var borderWidth: CGFloat = 1
    /// Neon glow around the edge (Midnight).
    var edgeGlow: NSColor?
    /// The highlight that follows the pointer across the glass.
    var specular: Float = 0.14
    var shadowOpacity: Float = 0.26
    var shadowRadius: CGFloat = 18
    /// Corner radius as a fraction of the shelf thickness.
    var cornerFactor: CGFloat = 0.34
    var accent: NSColor?
    var indicatorGlow: Float = 0.8
    var reflections = false
    /// Draws a perspective floor instead of a slab (Mirror).
    var floor = false
    var iconShadow: Float = 0
    var separatorOpacity: Float = 0.3
    /// Two colours used to draw the theme's swatch in Settings.
    var swatch: (NSColor, NSColor)

    static func style(for theme: ThemeID) -> ThemeStyle {
        switch theme {
        case .glass:
            return ThemeStyle(
                backdrop: .material(.popover),
                innerHighlight: 0.22,
                borderStart: .white.withAlphaComponent(0.55),
                borderEnd: .white.withAlphaComponent(0.12),
                specular: 0.16,
                shadowOpacity: 0.24,
                swatch: (NSColor(hex: 0xDCE7F7), NSColor(hex: 0x9FB6D9))
            )
        case .liquid:
            return ThemeStyle(
                backdrop: .liquidGlass(fallback: .fullScreenUI),
                innerHighlight: 0.32,
                borderStart: .white.withAlphaComponent(0.75),
                borderEnd: .white.withAlphaComponent(0.18),
                borderWidth: 1.2,
                specular: 0.34,
                shadowOpacity: 0.18,
                shadowRadius: 22,
                cornerFactor: 0.42,
                swatch: (NSColor(hex: 0xF4FBFF), NSColor(hex: 0xA8D8F0))
            )
        case .aurora:
            return ThemeStyle(
                backdrop: .material(.hudWindow),
                appearance: .darkAqua,
                auroraColors: [NSColor(hex: 0x7B5CFF), NSColor(hex: 0x22C1FF), NSColor(hex: 0x2EF2B5), NSColor(hex: 0xFF5FA8)],
                auroraOpacity: 0.5,
                innerHighlight: 0.16,
                borderStart: .white.withAlphaComponent(0.42),
                borderEnd: .white.withAlphaComponent(0.06),
                specular: 0.16,
                shadowOpacity: 0.32,
                accent: NSColor(hex: 0xA594FF),
                swatch: (NSColor(hex: 0x5B3FD9), NSColor(hex: 0x16B8C9))
            )
        case .midnight:
            return ThemeStyle(
                backdrop: .material(.hudWindow),
                appearance: .darkAqua,
                tintColors: [NSColor(hex: 0x050816), NSColor(hex: 0x111A3D)],
                tintOpacity: 0.62,
                innerHighlight: 0.07,
                borderStart: NSColor(hex: 0x00E5FF, alpha: 0.95),
                borderEnd: NSColor(hex: 0xFF2BD6, alpha: 0.85),
                borderWidth: 1.2,
                edgeGlow: NSColor(hex: 0x00E5FF),
                specular: 0.1,
                shadowOpacity: 0.4,
                accent: NSColor(hex: 0x00E5FF),
                indicatorGlow: 1,
                swatch: (NSColor(hex: 0x0B1030), NSColor(hex: 0x00B8D4))
            )
        case .sunset:
            return ThemeStyle(
                backdrop: .material(.popover),
                tintColors: [NSColor(hex: 0xFFB25B), NSColor(hex: 0xFF6F91), NSColor(hex: 0x9D6BFF)],
                tintOpacity: 0.42,
                innerHighlight: 0.26,
                borderStart: .white.withAlphaComponent(0.62),
                borderEnd: .white.withAlphaComponent(0.14),
                specular: 0.18,
                shadowOpacity: 0.26,
                accent: NSColor(hex: 0xFF8A5B),
                swatch: (NSColor(hex: 0xFFB25B), NSColor(hex: 0xB86BFF))
            )
        case .mirror:
            return ThemeStyle(
                backdrop: .material(.popover),
                innerHighlight: 0.34,
                borderStart: .white.withAlphaComponent(0.85),
                borderEnd: .white.withAlphaComponent(0.25),
                specular: 0.2,
                shadowOpacity: 0.22,
                shadowRadius: 12,
                reflections: true,
                floor: true,
                swatch: (NSColor(hex: 0xE8EEF5), NSColor(hex: 0x7D8FA6))
            )
        case .minimal:
            return ThemeStyle(
                backdrop: .none,
                innerHighlight: 0,
                borderStart: .clear,
                borderEnd: .clear,
                borderWidth: 0,
                specular: 0,
                shadowOpacity: 0,
                indicatorGlow: 1,
                iconShadow: 0.35,
                separatorOpacity: 0.45,
                swatch: (NSColor(hex: 0x2B2F36), NSColor(hex: 0x50555E))
            )
        }
    }

    /// The accent colour for indicators, ripples and glows.
    static func accentColor(for choice: AccentChoice, theme: ThemeStyle) -> NSColor {
        switch choice {
        case .theme: return theme.accent ?? .controlAccentColor
        case .system: return .controlAccentColor
        case .blue: return NSColor(hex: 0x0A84FF)
        case .purple: return NSColor(hex: 0xBF5AF2)
        case .pink: return NSColor(hex: 0xFF375F)
        case .red: return NSColor(hex: 0xFF453A)
        case .orange: return NSColor(hex: 0xFF9F0A)
        case .yellow: return NSColor(hex: 0xFFD60A)
        case .green: return NSColor(hex: 0x30D158)
        case .teal: return NSColor(hex: 0x40C8E0)
        case .graphite: return NSColor(hex: 0x98989D)
        }
    }
}
