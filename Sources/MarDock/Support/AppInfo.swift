import AppKit
import os

enum AppInfo {
    static let fallbackBundleIdentifier = "io.github.aliraza47.MarDock"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier
    }

    /// The XPC helper is named after the app's own bundle identifier.
    static var agentServiceName: String { bundleIdentifier + ".Agent" }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static let name = "MarDock"
}

let appLog = Logger(subsystem: AppInfo.bundleIdentifier, category: "app")

extension NSColor {
    /// An sRGB colour from a 0xRRGGBB literal.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Linear interpolation in sRGB.
    func mixed(with other: NSColor, amount: CGFloat) -> NSColor {
        let t = min(max(amount, 0), 1)
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return t < 0.5 ? self : other }
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t
        )
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
            .map { [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua].contains($0) } ?? false
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
