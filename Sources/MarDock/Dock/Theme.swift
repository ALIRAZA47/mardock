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
        ThemeStyle(recipe: .builtIn(theme))
    }

    /// What the renderer compares to know when to rebuild the glass.
    static func key(for recipe: ThemeRecipe) -> String {
        recipe.id + "|" + recipe.glass.rawValue + "|" + recipe.tone.rawValue
    }

    /// Turns a recipe (built in, or made in the theme editor) into the values
    /// the renderer uses.
    init(recipe r: ThemeRecipe) {
        switch r.glass {
        case .frosted: backdrop = .material(.popover)
        case .smoked: backdrop = .material(.hudWindow)
        case .liquid: backdrop = .liquidGlass(fallback: .fullScreenUI)
        case .none: backdrop = .none
        }
        switch r.tone {
        case .system: appearance = nil
        case .light: appearance = .aqua
        case .dark: appearance = .darkAqua
        }
        tintColors = r.tint.map(NSColor.init(themeColor:))
        tintOpacity = Float(r.tintOpacity)
        auroraColors = r.aurora.map(NSColor.init(themeColor:))
        auroraOpacity = Float(r.auroraOpacity)
        innerHighlight = Float(r.innerHighlight)
        borderStart = NSColor(themeColor: r.borderStart)
        borderEnd = NSColor(themeColor: r.borderEnd)
        borderWidth = CGFloat(r.borderWidth)
        edgeGlow = r.edgeGlow.map(NSColor.init(themeColor:))
        specular = Float(r.specular)
        shadowOpacity = Float(r.shadowOpacity)
        shadowRadius = CGFloat(r.shadowRadius)
        cornerFactor = CGFloat(r.cornerFactor)
        accent = r.accent.map(NSColor.init(themeColor:))
        indicatorGlow = Float(r.indicatorGlow)
        reflections = r.reflections
        floor = r.floor
        iconShadow = Float(r.iconShadow)
        separatorOpacity = Float(r.separatorOpacity)
        let swatchColors = r.swatch.count >= 2 ? r.swatch : ThemeRecipe.builtIn(.glass).swatch
        swatch = (NSColor(themeColor: swatchColors[0]), NSColor(themeColor: swatchColors[1]))
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

extension NSColor {
    convenience init(themeColor c: ThemeColor) {
        self.init(srgbRed: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha))
    }
}

extension ThemeColor {
    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }
}
