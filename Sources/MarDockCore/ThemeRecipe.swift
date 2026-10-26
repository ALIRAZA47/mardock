import Foundation

/// A colour as themes store it: sRGB components from 0 to 1.
public struct ThemeColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.unit(red)
        self.green = Self.unit(green)
        self.blue = Self.unit(blue)
        self.alpha = Self.unit(alpha)
    }

    /// From a 0xRRGGBB literal.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public static func white(_ alpha: Double) -> ThemeColor { ThemeColor(red: 1, green: 1, blue: 1, alpha: alpha) }
    public static let clear = ThemeColor(red: 0, green: 0, blue: 0, alpha: 0)

    public func withAlpha(_ alpha: Double) -> ThemeColor {
        ThemeColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// "#RRGGBB", or "#RRGGBBAA" when not opaque.
    public var hexString: String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int((v * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    private enum CodingKeys: String, CodingKey { case red, green, blue, alpha }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            red: try c.decode(Double.self, forKey: .red),
            green: try c.decode(Double.self, forKey: .green),
            blue: try c.decode(Double.self, forKey: .blue),
            alpha: (try? c.decodeIfPresent(Double.self, forKey: .alpha)) ?? 1
        )
    }
}

/// Everything that decides how a theme looks, as plain data: the seven
/// built-in themes are recipes, and so are the ones people make in the
/// theme editor and share as files.
public struct ThemeRecipe: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The glass behind the icons.
    public enum Glass: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Light frosted glass that follows light and dark mode.
        case frosted
        /// Darker, smoky glass.
        case smoked
        /// Clear glass; the system's Liquid Glass on macOS 26.
        case liquid
        /// No shelf at all.
        case none

        public var id: String { rawValue }
    }

    /// Whether the glass and labels follow the system appearance.
    public enum Tone: String, Codable, CaseIterable, Sendable, Identifiable {
        case system
        case light
        case dark

        public var id: String { rawValue }
    }

    /// `builtin:<theme>` for the built-in themes, `theme:<token>` for others.
    public var id: String
    public var name: String
    public var glass: Glass = .frosted
    public var tone: Tone = .system
    /// Up to three colours tinting the glass, left to right.
    public var tint: [ThemeColor] = []
    public var tintOpacity: Double = 0
    /// Up to four colours drifting slowly under the glass.
    public var aurora: [ThemeColor] = []
    public var auroraOpacity: Double = 0
    /// Soft light along the inner edge of the glass.
    public var innerHighlight: Double = 0.18
    public var borderStart: ThemeColor = .white(0.5)
    public var borderEnd: ThemeColor = .white(0.1)
    public var borderWidth: Double = 1
    /// A neon glow around the edge.
    public var edgeGlow: ThemeColor?
    /// The highlight that follows the pointer along the glass.
    public var specular: Double = 0.14
    public var shadowOpacity: Double = 0.26
    public var shadowRadius: Double = 18
    /// Corner radius as a fraction of the shelf's thickness.
    public var cornerFactor: Double = 0.34
    /// Indicators, ripples and glows; nil means the system accent colour.
    public var accent: ThemeColor?
    public var indicatorGlow: Double = 0.8
    public var reflections = false
    /// A perspective floor instead of a slab (needs the bottom position).
    public var floor = false
    public var iconShadow: Double = 0
    public var separatorOpacity: Double = 0.3
    /// Two colours for the theme's swatch in Settings.
    public var swatch: [ThemeColor] = [ThemeColor(hex: 0xDCE7F7), ThemeColor(hex: 0x9FB6D9)]

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static let maxTint = 3
    public static let maxAurora = 4
    public static let maxFileBytes = 64 * 1024

    public static let opacityRange: ClosedRange<Double> = 0...1
    public static let borderWidthRange: ClosedRange<Double> = 0...4
    public static let shadowRadiusRange: ClosedRange<Double> = 0...40
    public static let cornerRange: ClosedRange<Double> = 0...0.5

    public var isBuiltIn: Bool { id.hasPrefix("builtin:") }

    /// A fresh copy, with a new identity, that the user can edit.
    public func duplicate(named newName: String) -> ThemeRecipe {
        var copy = self
        copy.id = "theme:" + UUID().uuidString.prefix(8).lowercased()
        copy.name = InputValidation.sanitizedDisplayName(newName)
        return copy.sanitized()
    }

    /// Every number clamped, every list capped, the name cleaned.
    public func sanitized() -> ThemeRecipe {
        var r = self
        func unit(_ v: Double, _ fallback: Double) -> Double { DockSettings.clamp(v, Self.opacityRange, fallback: fallback) }
        let d = ThemeRecipe(id: "", name: "")
        r.name = InputValidation.sanitizedDisplayName(name)
        if r.name.isEmpty { r.name = "Untitled" }
        r.tint = Array(tint.prefix(Self.maxTint))
        r.aurora = Array(aurora.prefix(Self.maxAurora))
        r.tintOpacity = unit(tintOpacity, d.tintOpacity)
        r.auroraOpacity = unit(auroraOpacity, d.auroraOpacity)
        r.innerHighlight = unit(innerHighlight, d.innerHighlight)
        r.borderWidth = DockSettings.clamp(borderWidth, Self.borderWidthRange, fallback: d.borderWidth)
        r.specular = unit(specular, d.specular)
        r.shadowOpacity = unit(shadowOpacity, d.shadowOpacity)
        r.shadowRadius = DockSettings.clamp(shadowRadius, Self.shadowRadiusRange, fallback: d.shadowRadius)
        r.cornerFactor = DockSettings.clamp(cornerFactor, Self.cornerRange, fallback: d.cornerFactor)
        r.indicatorGlow = unit(indicatorGlow, d.indicatorGlow)
        r.iconShadow = unit(iconShadow, d.iconShadow)
        r.separatorOpacity = unit(separatorOpacity, d.separatorOpacity)
        if r.swatch.count < 2 { r.swatch = d.swatch }
        r.swatch = Array(r.swatch.prefix(2))
        return r
    }

    /// `theme:` followed by 1–36 letters, digits or hyphens, or a built-in id.
    public static func isValidID(_ id: String) -> Bool {
        if id.hasPrefix("builtin:") { return ThemeID(rawValue: String(id.dropFirst(8))) != nil }
        guard id.hasPrefix("theme:") else { return false }
        let token = id.dropFirst(6)
        return (1...36).contains(token.count) && token.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-": return true
            default: return false
            }
        }
    }

    // MARK: Files

    /// Reads a theme file. Unknown keys are ignored, missing ones get
    /// defaults and numbers are clamped, so a hand-edited or hostile file
    /// can only ever produce a valid theme.
    public static func decode(_ data: Data) -> ThemeRecipe? {
        guard data.count <= maxFileBytes, let recipe = try? JSONDecoder().decode(ThemeRecipe.self, from: data) else { return nil }
        return recipe
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(sanitized())
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, glass, tone, tint, tintOpacity, aurora, auroraOpacity, innerHighlight
        case borderStart, borderEnd, borderWidth, edgeGlow, specular, shadowOpacity, shadowRadius
        case cornerFactor, accent, indicatorGlow, reflections, floor, iconShadow, separatorOpacity, swatch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = (try? c.decode(String.self, forKey: .id)) ?? ""
        var r = ThemeRecipe(id: Self.isValidID(id) ? id : "theme:" + UUID().uuidString.prefix(8).lowercased(), name: "")
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        r.name = value(.name, "Untitled")
        r.glass = value(.glass, r.glass)
        r.tone = value(.tone, r.tone)
        r.tint = value(.tint, r.tint)
        r.tintOpacity = value(.tintOpacity, r.tintOpacity)
        r.aurora = value(.aurora, r.aurora)
        r.auroraOpacity = value(.auroraOpacity, r.auroraOpacity)
        r.innerHighlight = value(.innerHighlight, r.innerHighlight)
        r.borderStart = value(.borderStart, r.borderStart)
        r.borderEnd = value(.borderEnd, r.borderEnd)
        r.borderWidth = value(.borderWidth, r.borderWidth)
        r.edgeGlow = value(.edgeGlow, r.edgeGlow)
        r.specular = value(.specular, r.specular)
        r.shadowOpacity = value(.shadowOpacity, r.shadowOpacity)
        r.shadowRadius = value(.shadowRadius, r.shadowRadius)
        r.cornerFactor = value(.cornerFactor, r.cornerFactor)
        r.accent = value(.accent, r.accent)
        r.indicatorGlow = value(.indicatorGlow, r.indicatorGlow)
        r.reflections = value(.reflections, r.reflections)
        r.floor = value(.floor, r.floor)
        r.iconShadow = value(.iconShadow, r.iconShadow)
        r.separatorOpacity = value(.separatorOpacity, r.separatorOpacity)
        r.swatch = value(.swatch, r.swatch)
        self = r.sanitized()
    }
}

extension ThemeRecipe {
    /// The built-in themes, as recipes.
    public static func builtIn(_ theme: ThemeID) -> ThemeRecipe {
        var r = ThemeRecipe(id: "builtin:" + theme.rawValue, name: theme.displayName)
        switch theme {
        case .glass:
            r.innerHighlight = 0.22
            r.borderStart = .white(0.55)
            r.borderEnd = .white(0.12)
            r.specular = 0.16
            r.shadowOpacity = 0.24
            r.swatch = [ThemeColor(hex: 0xDCE7F7), ThemeColor(hex: 0x9FB6D9)]
        case .liquid:
            r.glass = .liquid
            r.innerHighlight = 0.32
            r.borderStart = .white(0.75)
            r.borderEnd = .white(0.18)
            r.borderWidth = 1.2
            r.specular = 0.34
            r.shadowOpacity = 0.18
            r.shadowRadius = 22
            r.cornerFactor = 0.42
            r.swatch = [ThemeColor(hex: 0xF4FBFF), ThemeColor(hex: 0xA8D8F0)]
        case .aurora:
            r.glass = .smoked
            r.tone = .dark
            r.aurora = [ThemeColor(hex: 0x7B5CFF), ThemeColor(hex: 0x22C1FF), ThemeColor(hex: 0x2EF2B5), ThemeColor(hex: 0xFF5FA8)]
            r.auroraOpacity = 0.5
            r.innerHighlight = 0.16
            r.borderStart = .white(0.42)
            r.borderEnd = .white(0.06)
            r.specular = 0.16
            r.shadowOpacity = 0.32
            r.accent = ThemeColor(hex: 0xA594FF)
            r.swatch = [ThemeColor(hex: 0x5B3FD9), ThemeColor(hex: 0x16B8C9)]
        case .midnight:
            r.glass = .smoked
            r.tone = .dark
            r.tint = [ThemeColor(hex: 0x050816), ThemeColor(hex: 0x111A3D)]
            r.tintOpacity = 0.62
            r.innerHighlight = 0.07
            r.borderStart = ThemeColor(hex: 0x00E5FF, alpha: 0.95)
            r.borderEnd = ThemeColor(hex: 0xFF2BD6, alpha: 0.85)
            r.borderWidth = 1.2
            r.edgeGlow = ThemeColor(hex: 0x00E5FF)
            r.specular = 0.1
            r.shadowOpacity = 0.4
            r.accent = ThemeColor(hex: 0x00E5FF)
            r.indicatorGlow = 1
            r.swatch = [ThemeColor(hex: 0x0B1030), ThemeColor(hex: 0x00B8D4)]
        case .sunset:
            r.tint = [ThemeColor(hex: 0xFFB25B), ThemeColor(hex: 0xFF6F91), ThemeColor(hex: 0x9D6BFF)]
            r.tintOpacity = 0.42
            r.innerHighlight = 0.26
            r.borderStart = .white(0.62)
            r.borderEnd = .white(0.14)
            r.specular = 0.18
            r.shadowOpacity = 0.26
            r.accent = ThemeColor(hex: 0xFF8A5B)
            r.swatch = [ThemeColor(hex: 0xFFB25B), ThemeColor(hex: 0xB86BFF)]
        case .mirror:
            r.innerHighlight = 0.34
            r.borderStart = .white(0.85)
            r.borderEnd = .white(0.25)
            r.specular = 0.2
            r.shadowOpacity = 0.22
            r.shadowRadius = 12
            r.reflections = true
            r.floor = true
            r.swatch = [ThemeColor(hex: 0xE8EEF5), ThemeColor(hex: 0x7D8FA6)]
        case .minimal:
            r.glass = .none
            r.innerHighlight = 0
            r.borderStart = .clear
            r.borderEnd = .clear
            r.borderWidth = 0
            r.specular = 0
            r.shadowOpacity = 0
            r.indicatorGlow = 1
            r.iconShadow = 0.35
            r.separatorOpacity = 0.45
            r.swatch = [ThemeColor(hex: 0x2B2F36), ThemeColor(hex: 0x50555E)]
        }
        return r
    }
}

extension ThemeRecipe {
    public static let maxCustomThemes = 64

    /// Decodes the stored list of the user's themes, dropping invalid,
    /// built-in or repeated entries.
    public static func decodeList(_ data: Data?) -> [ThemeRecipe] {
        guard let data, data.count <= maxCustomThemes * maxFileBytes,
              let raw = try? JSONDecoder().decode([Lossy<ThemeRecipe>].self, from: data)
        else { return [] }
        var seen = Set<String>()
        return Array(raw.compactMap(\.value).filter { !$0.isBuiltIn && seen.insert($0.id).inserted }.prefix(maxCustomThemes))
    }

    public static func encodeList(_ themes: [ThemeRecipe]) -> Data? {
        try? JSONEncoder().encode(Array(themes.filter { !$0.isBuiltIn }.map { $0.sanitized() }.prefix(maxCustomThemes)))
    }
}
