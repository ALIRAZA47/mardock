import Foundation

/// A value stored in the macOS Dock's preferences.
public enum SystemDockValue: Codable, Equatable, Hashable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
}

/// One change to the macOS Dock's preferences. `nil` removes the key, which
/// restores the macOS default.
public struct SystemDockChange: Codable, Equatable, Sendable {
    public var key: String
    public var value: SystemDockValue?

    public init(key: String, value: SystemDockValue?) {
        self.key = key
        self.value = value
    }
}

/// The complete list of macOS Dock preferences MarDock may read or write.
///
/// The helper refuses anything not described here, so even a compromised app
/// process can't use it to write arbitrary preferences: it can only set these
/// keys, to values of the right type and within these ranges.
public enum SystemDockSchema {
    public static let domain = "com.apple.dock"

    public enum Kind: Equatable, Sendable {
        case bool
        case integer(ClosedRange<Double>)
        case real(ClosedRange<Double>)
        case choice([String])
    }

    public static let keys: [String: Kind] = [
        "autohide": .bool,
        "autohide-delay": .real(0...1000),
        "autohide-time-modifier": .real(0...5),
        "tilesize": .integer(16...128),
        "magnification": .bool,
        "largesize": .integer(16...128),
        "orientation": .choice(["bottom", "left", "right"]),
        "mineffect": .choice(["genie", "scale", "suck"]),
        "minimize-to-application": .bool,
        "show-recents": .bool,
        "launchanim": .bool,
        "show-process-indicators": .bool,
        "static-only": .bool,
        "showhidden": .bool,
        "scroll-to-open": .bool,
    ]

    /// The delay MarDock uses to keep the macOS Dock out of the way: with
    /// auto-hide on, the Dock would need a 1000-second hover to appear.
    public static let hiddenDelay: Double = 1000

    /// Keys MarDock changes to hide the macOS Dock (and restores afterwards).
    public static let hidingKeys = ["autohide", "autohide-delay"]

    public static func isValid(key: String, value: SystemDockValue?) -> Bool {
        guard let kind = keys[key] else { return false }
        guard let value else { return true }
        switch (kind, value) {
        case (.bool, .bool):
            return true
        case let (.integer(range), .number(n)), let (.real(range), .number(n)):
            return n.isFinite && range.contains(n)
        case let (.choice(options), .string(s)):
            return options.contains(s)
        default:
            return false
        }
    }

    public static func isValid(_ change: SystemDockChange) -> Bool {
        isValid(key: change.key, value: change.value)
    }

    /// Validates a batch: every change valid, no key twice, bounded size.
    public static func isValid(_ changes: [SystemDockChange]) -> Bool {
        guard !changes.isEmpty, changes.count <= keys.count else { return false }
        var seen = Set<String>()
        for change in changes {
            guard seen.insert(change.key).inserted, isValid(change) else { return false }
        }
        return true
    }

    /// Changes that hide the macOS Dock.
    public static var hideChanges: [SystemDockChange] {
        [
            SystemDockChange(key: "autohide", value: .bool(true)),
            SystemDockChange(key: "autohide-delay", value: .number(hiddenDelay)),
        ]
    }

    /// Changes that put back what was there before hiding. Keys that had no
    /// value are removed, restoring the system default.
    public static func restoreChanges(from backup: [String: SystemDockValue]) -> [SystemDockChange] {
        hidingKeys.map { key in
            let value = backup[key].flatMap { isValid(key: key, value: $0) ? $0 : nil }
            return SystemDockChange(key: key, value: value)
        }
    }

    /// Whether the given preferences currently hide the macOS Dock the way MarDock does.
    public static func looksHidden(_ values: [String: SystemDockValue]) -> Bool {
        guard case .bool(true)? = values["autohide"], case let .number(delay)? = values["autohide-delay"] else { return false }
        return delay >= 100
    }
}

/// An app pinned in the macOS Dock, as found in its `persistent-apps` list.
public struct ImportedDockApp: Codable, Equatable, Sendable {
    public var bundleIdentifier: String
    public var path: String
    public var name: String

    public init(bundleIdentifier: String, path: String, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.name = name
    }
}

/// Parses the macOS Dock's `persistent-apps` preference defensively: wrong
/// types, missing fields, odd URLs and oversized lists are all skipped.
public enum PersistentAppsParser {
    public static let maxEntries = 100

    public static func parse(_ plist: Any?) -> [ImportedDockApp] {
        guard let tiles = plist as? [Any] else { return [] }
        var result: [ImportedDockApp] = []
        var seen = Set<String>()
        for tile in tiles.prefix(maxEntries * 2) {
            guard let tile = tile as? [String: Any],
                  let data = tile["tile-data"] as? [String: Any],
                  let bundleIdentifier = data["bundle-identifier"] as? String,
                  InputValidation.isValidBundleIdentifier(bundleIdentifier),
                  let fileData = data["file-data"] as? [String: Any],
                  let urlString = fileData["_CFURLString"] as? String,
                  let path = InputValidation.appPath(fromFileURLString: urlString)
            else { continue }
            guard seen.insert(bundleIdentifier.lowercased()).inserted else { continue }
            let label = (data["file-label"] as? String).map(InputValidation.sanitizedDisplayName) ?? ""
            result.append(ImportedDockApp(bundleIdentifier: bundleIdentifier, path: path, name: label))
            if result.count == maxEntries { break }
        }
        return result
    }
}
