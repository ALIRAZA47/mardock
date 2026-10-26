import Foundation

/// An app the user keeps in the dock.
public struct PinnedApp: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var bundleIdentifier: String
    /// Last known location of the app bundle.
    public var path: String
    /// Cached display name.
    public var name: String

    public init?(bundleIdentifier: String, path: String, name: String) {
        guard InputValidation.isValidBundleIdentifier(bundleIdentifier),
              InputValidation.isPlausibleAppPath(path)
        else { return nil }
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        let cleanName = InputValidation.sanitizedDisplayName(name)
        self.name = cleanName.isEmpty ? Self.fallbackName(for: path) : cleanName
    }

    public var id: String { DockIdentity.app(bundleIdentifier) }

    static func fallbackName(for path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        let base = last.lowercased().hasSuffix(".app") ? String(last.dropLast(4)) : last
        return InputValidation.sanitizedDisplayName(base)
    }

    private enum CodingKeys: String, CodingKey { case bundleIdentifier, path, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        let path = try c.decode(String.self, forKey: .path)
        let name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        guard let valid = PinnedApp(bundleIdentifier: bundleIdentifier, path: path, name: name) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Invalid pinned app"))
        }
        self = valid
    }

    public static let maxCount = 128

    /// Decodes a stored list, dropping invalid or duplicate entries.
    public static func decodeList(_ data: Data?) -> [PinnedApp]? {
        guard let data, data.count <= 512 * 1024 else { return nil }
        guard let raw = try? JSONDecoder().decode([LossyPinnedApp].self, from: data) else { return nil }
        var seen = Set<String>()
        var result: [PinnedApp] = []
        for entry in raw {
            guard let app = entry.app, seen.insert(app.id).inserted else { continue }
            result.append(app)
            if result.count == maxCount { break }
        }
        return result
    }

    public static func encodeList(_ apps: [PinnedApp]) -> Data? {
        try? JSONEncoder().encode(Array(apps.prefix(maxCount)))
    }

    private struct LossyPinnedApp: Decodable {
        var app: PinnedApp?
        init(from decoder: Decoder) throws {
            app = try? PinnedApp(from: decoder)
        }
    }
}

/// Stable identifiers for dock tiles.
public enum DockIdentity {
    public static let finderBundleIdentifier = "com.apple.finder"
    public static let finder = app(finderBundleIdentifier)
    public static let trash = "trash"
    public static let runningSeparator = "separator:running"
    public static let trashSeparator = "separator:trash"

    public static func app(_ bundleIdentifier: String) -> String {
        "app:" + bundleIdentifier.lowercased()
    }

    public static func process(_ pid: Int32) -> String {
        "pid:\(pid)"
    }
}

/// What the dock knows about a running app.
public struct RunningAppSnapshot: Equatable, Sendable {
    /// `DockIdentity.app(...)`, or `DockIdentity.process(...)` for apps without a bundle identifier.
    public var key: String
    public var bundleIdentifier: String?
    public var pid: Int32
    public var name: String
    public var isActive: Bool
    public var isHidden: Bool
    public var isFinishedLaunching: Bool
    /// Order in which MarDock first saw the app, for stable placement.
    public var order: Int

    public init(key: String, bundleIdentifier: String?, pid: Int32, name: String, isActive: Bool, isHidden: Bool, isFinishedLaunching: Bool, order: Int) {
        self.key = key
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.name = name
        self.isActive = isActive
        self.isHidden = isHidden
        self.isFinishedLaunching = isFinishedLaunching
        self.order = order
    }
}

/// One tile of the dock.
public struct DockEntry: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case finder
        case pinned(PinnedApp)
        case running
        case separator
        case trash
    }

    public var id: String
    public var kind: Kind
    public var running: RunningAppSnapshot?
    public var isLaunching: Bool

    public var isPinned: Bool {
        if case .pinned = kind { return true }
        return false
    }

    public var isApp: Bool {
        switch kind {
        case .finder, .pinned, .running: return true
        case .separator, .trash: return false
        }
    }

    public var spec: DockItemSpec {
        let kind: DockItemKind
        switch self.kind {
        case .separator: kind = .separator
        case .trash: kind = .trash
        default: kind = .app
        }
        return DockItemSpec(
            id: id,
            kind: kind,
            isRunning: running != nil,
            isActive: running?.isActive ?? false,
            isHidden: running?.isHidden ?? false,
            isLaunching: isLaunching || (running.map { !$0.isFinishedLaunching } ?? false)
        )
    }
}

/// Merges pinned and running apps into the ordered list of tiles:
/// Finder, pinned apps, | running apps that aren't pinned, | Trash.
public enum DockContentBuilder {
    public static func build(
        pins: [PinnedApp],
        running: [RunningAppSnapshot],
        launching: Set<String> = [],
        showRunningApps: Bool = true,
        showTrash: Bool = true
    ) -> [DockEntry] {
        var runningByKey: [String: RunningAppSnapshot] = [:]
        for app in running where runningByKey[app.key] == nil {
            runningByKey[app.key] = app
        }

        var entries: [DockEntry] = [
            DockEntry(id: DockIdentity.finder, kind: .finder, running: runningByKey[DockIdentity.finder], isLaunching: launching.contains(DockIdentity.finder)),
        ]
        var used: Set<String> = [DockIdentity.finder]

        for pin in pins where !used.contains(pin.id) {
            used.insert(pin.id)
            entries.append(DockEntry(id: pin.id, kind: .pinned(pin), running: runningByKey[pin.id], isLaunching: launching.contains(pin.id)))
        }

        if showRunningApps {
            let extras = running
                .filter { !used.contains($0.key) }
                .sorted { $0.order < $1.order }
            var added = false
            for app in extras where !used.contains(app.key) {
                if !added {
                    entries.append(DockEntry(id: DockIdentity.runningSeparator, kind: .separator, running: nil, isLaunching: false))
                    added = true
                }
                used.insert(app.key)
                entries.append(DockEntry(id: app.key, kind: .running, running: app, isLaunching: launching.contains(app.key)))
            }
        }

        if showTrash {
            entries.append(DockEntry(id: DockIdentity.trashSeparator, kind: .separator, running: nil, isLaunching: false))
            entries.append(DockEntry(id: DockIdentity.trash, kind: .trash, running: nil, isLaunching: false))
        }
        return entries
    }
}
