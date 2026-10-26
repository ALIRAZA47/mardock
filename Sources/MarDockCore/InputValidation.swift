import Foundation

/// Validation for every piece of data that crosses a trust boundary: values
/// read from preferences, received over XPC, dropped from other apps or read
/// from the macOS Dock's own preferences.
public enum InputValidation {
    public static let maxBundleIdentifierLength = 255
    public static let maxPathLength = 1024
    public static let maxDisplayNameLength = 80

    /// Bundle identifiers: reverse-DNS characters only. Underscores are not
    /// strictly legal but real apps ship with them, so they are accepted.
    public static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maxBundleIdentifierLength else { return false }
        guard !value.hasPrefix("."), !value.hasSuffix("."), !value.contains("..") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", ".", "_": return true
            default: return false
            }
        }
    }

    /// An absolute path to an application bundle, without relative components.
    public static func isPlausibleAppPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= maxPathLength else { return false }
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.lowercased().hasSuffix(".app")
    }

    /// Trims, strips control characters and caps the length of a name we show.
    public static func sanitizedDisplayName(_ name: String) -> String {
        let cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || scalar.properties.generalCategory == .format)
        }))
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxDisplayNameLength { return trimmed }
        return String(trimmed.prefix(maxDisplayNameLength - 1)) + "…"
    }

    /// Path of a `file://` URL string as stored by the macOS Dock.
    public static func appPath(fromFileURLString string: String) -> String? {
        guard string.utf8.count <= maxPathLength * 3,
              let url = URL(string: string), url.isFileURL
        else { return nil }
        let path = url.path
        return isPlausibleAppPath(path) ? path : nil
    }
}
