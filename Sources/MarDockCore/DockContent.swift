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
    public static let share = "share"
    public static let runningSeparator = "separator:running"
    public static let trashSeparator = "separator:trash"

    public static func app(_ bundleIdentifier: String) -> String {
        "app:" + bundleIdentifier.lowercased()
    }

    public static func process(_ pid: Int32) -> String {
        "pid:\(pid)"
    }

    /// A minimized window's tile: stable while the window stays where it is
    /// in its app's list and keeps its title.
    public static func window(_ window: WindowInfo) -> String {
        // FNV-1a: the same in every process, unlike `hashValue`.
        var hash: UInt32 = 2_166_136_261
        for byte in window.title.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return "window:\(window.pid):\(window.index):" + String(hash, radix: 16)
    }

    /// A new identifier for a spacer or divider the user adds.
    public static func newTile(_ kind: UserTileKind) -> String {
        kind.rawValue + ":" + UUID().uuidString.prefix(8).lowercased()
    }

    public enum UserTileKind: String, Sendable {
        case spacer
        case divider
        case folder
        case profile
    }

    /// `spacer:`, `divider:`… followed by 1–36 letters, digits or hyphens.
    public static func isValidTileID(_ id: String, kind: UserTileKind) -> Bool {
        let prefix = kind.rawValue + ":"
        guard id.hasPrefix(prefix) else { return false }
        let token = id.dropFirst(prefix.count)
        return (1...36).contains(token.count) && token.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-": return true
            default: return false
            }
        }
    }
}

/// A folder kept in the dock, shown as a stack of its newest files.
public struct FolderStack: Codable, Equatable, Hashable, Sendable {
    public enum Display: String, Codable, CaseIterable, Sendable {
        /// The newest files, piled up.
        case stack
        /// The folder's own icon.
        case folder
    }

    public enum Sorting: String, Codable, CaseIterable, Sendable {
        case dateAdded
        case dateModified
        case name
    }

    public var id: String
    public var name: String
    /// Where the folder was when it was added (for display; the bookmark is
    /// what finds it).
    public var path: String
    /// A security-scoped bookmark: the sandbox's record that the user chose
    /// this folder. Without it MarDock can't open the folder.
    public var bookmark: Data
    public var display: Display
    public var sorting: Sorting

    public static let maxBookmarkBytes = 16 * 1024

    public init?(id: String, name: String, path: String, bookmark: Data, display: Display = .stack, sorting: Sorting = .dateAdded) {
        guard DockIdentity.isValidTileID(id, kind: .folder), InputValidation.isPlausibleAbsolutePath(path),
              !bookmark.isEmpty, bookmark.count <= Self.maxBookmarkBytes
        else { return nil }
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.display = display
        self.sorting = sorting
        let cleanName = InputValidation.sanitizedDisplayName(name)
        self.name = cleanName.isEmpty ? InputValidation.sanitizedDisplayName(path.split(separator: "/").last.map(String.init) ?? "Folder") : cleanName
    }

    private enum CodingKeys: String, CodingKey { case id, name, path, bookmark, display, sorting }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let stack = FolderStack(
            id: try c.decode(String.self, forKey: .id),
            name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "",
            path: try c.decode(String.self, forKey: .path),
            bookmark: try c.decode(Data.self, forKey: .bookmark),
            display: (try? c.decodeIfPresent(Display.self, forKey: .display)) ?? .stack,
            sorting: (try? c.decodeIfPresent(Sorting.self, forKey: .sorting)) ?? .dateAdded
        ) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Invalid folder"))
        }
        self = stack
    }
}

/// Something the user keeps in the dock, in the order they chose.
public enum DockItem: Equatable, Hashable, Sendable, Identifiable {
    case app(PinnedApp)
    /// An empty slot, to space groups of apps apart.
    case spacer(id: String)
    /// A line between groups of apps; its title shows on hover.
    case divider(id: String, title: String)
    /// Files dropped on it go to the share sheet (AirDrop, Mail, Messages…).
    case share
    /// A folder, shown as a stack of its newest files.
    case folder(FolderStack)

    public static let maxCount = 128

    public static func newSpacer() -> DockItem {
        .spacer(id: DockIdentity.newTile(.spacer))
    }

    public static func newDivider(title: String = "") -> DockItem {
        .divider(id: DockIdentity.newTile(.divider), title: InputValidation.sanitizedDisplayName(title))
    }

    public var id: String {
        switch self {
        case let .app(app): return app.id
        case let .spacer(id): return id
        case let .divider(id, _): return id
        case .share: return DockIdentity.share
        case let .folder(stack): return stack.id
        }
    }

    public var app: PinnedApp? {
        if case let .app(app) = self { return app }
        return nil
    }

    /// Decodes a stored list, dropping invalid or duplicate entries.
    public static func decodeList(_ data: Data?) -> [DockItem]? {
        guard let data, data.count <= 512 * 1024 else { return nil }
        guard let raw = try? JSONDecoder().decode([Lossy].self, from: data) else { return nil }
        var seen = Set<String>()
        var result: [DockItem] = []
        for entry in raw {
            guard let item = entry.item, seen.insert(item.id).inserted else { continue }
            result.append(item)
            if result.count == maxCount { break }
        }
        return result
    }

    public static func encodeList(_ items: [DockItem]) -> Data? {
        try? JSONEncoder().encode(Array(items.prefix(maxCount)))
    }

    private struct Lossy: Decodable {
        var item: DockItem?
        init(from decoder: Decoder) throws {
            item = try? DockItem(from: decoder)
        }
    }
}

extension DockItem: Codable {
    private enum CodingKeys: String, CodingKey { case type, app, id, title, folder }
    private enum Kind: String, Codable { case app, spacer, divider, share, folder }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func invalid(_ what: String) -> DecodingError {
            .dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Invalid \(what)"))
        }
        switch try c.decode(Kind.self, forKey: .type) {
        case .app:
            self = .app(try c.decode(PinnedApp.self, forKey: .app))
        case .spacer:
            let id = try c.decode(String.self, forKey: .id)
            guard DockIdentity.isValidTileID(id, kind: .spacer) else { throw invalid("spacer") }
            self = .spacer(id: id)
        case .divider:
            let id = try c.decode(String.self, forKey: .id)
            guard DockIdentity.isValidTileID(id, kind: .divider) else { throw invalid("divider") }
            let title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
            self = .divider(id: id, title: InputValidation.sanitizedDisplayName(title))
        case .share:
            self = .share
        case .folder:
            self = .folder(try c.decode(FolderStack.self, forKey: .folder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .app(app):
            try c.encode(Kind.app, forKey: .type)
            try c.encode(app, forKey: .app)
        case let .spacer(id):
            try c.encode(Kind.spacer, forKey: .type)
            try c.encode(id, forKey: .id)
        case let .divider(id, title):
            try c.encode(Kind.divider, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
        case .share:
            try c.encode(Kind.share, forKey: .type)
        case let .folder(stack):
            try c.encode(Kind.folder, forKey: .type)
            try c.encode(stack, forKey: .folder)
        }
    }
}

/// Apps used recently, most recent first.
public struct RecentApps: Equatable, Sendable {
    public private(set) var apps: [PinnedApp]
    public static let capacity = 12

    public init(_ apps: [PinnedApp] = []) {
        var seen = Set<String>()
        self.apps = Array(apps.filter { seen.insert($0.id).inserted }.prefix(Self.capacity))
    }

    /// Moves `app` to the front.
    public mutating func note(_ app: PinnedApp) {
        apps.removeAll { $0.id == app.id }
        apps.insert(app, at: 0)
        if apps.count > Self.capacity { apps.removeLast(apps.count - Self.capacity) }
    }

    public mutating func remove(_ id: String) {
        apps.removeAll { $0.id == id }
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
        /// A recently used app that is neither kept nor running.
        case recent(PinnedApp)
        case separator
        case trash
        case spacer
        case divider(title: String)
        case share
        case folder(FolderStack)
        /// A minimized window; clicking it brings the window back.
        case window(WindowInfo)
    }

    public var id: String
    public var kind: Kind
    public var running: RunningAppSnapshot?
    public var isLaunching: Bool

    public init(id: String, kind: Kind, running: RunningAppSnapshot?, isLaunching: Bool) {
        self.id = id
        self.kind = kind
        self.running = running
        self.isLaunching = isLaunching
    }

    /// An app the user keeps in the dock.
    public var isPinned: Bool {
        if case .pinned = kind { return true }
        return false
    }

    /// Anything in the user's own list: kept apps, spacers, dividers, the Share tile.
    public var isKept: Bool {
        switch kind {
        case .pinned, .spacer, .divider, .share, .folder: return true
        case .finder, .running, .recent, .separator, .trash, .window: return false
        }
    }

    public var isRecent: Bool {
        if case .recent = kind { return true }
        return false
    }

    public var isApp: Bool {
        switch kind {
        case .finder, .pinned, .running, .recent: return true
        case .separator, .trash, .spacer, .divider, .share, .folder, .window: return false
        }
    }

    /// The app this tile stands for while it isn't running.
    public var app: PinnedApp? {
        switch kind {
        case let .pinned(app), let .recent(app): return app
        default: return nil
        }
    }

    public var spec: DockItemSpec {
        let kind: DockItemKind
        var hasLabel = true
        switch self.kind {
        case .separator:
            kind = .separator
            hasLabel = false
        case .trash:
            kind = .trash
        case .spacer:
            kind = .spacer
            hasLabel = false
        case let .divider(title):
            kind = .divider
            hasLabel = !title.isEmpty
        case .finder, .pinned, .running, .recent, .share, .folder, .window:
            kind = .app
        }
        return DockItemSpec(
            id: id,
            kind: kind,
            isRunning: running != nil,
            isActive: running?.isActive ?? false,
            isHidden: running?.isHidden ?? false,
            isLaunching: isLaunching || (running.map { !$0.isFinishedLaunching } ?? false),
            hasLabel: hasLabel
        )
    }
}

/// Merges the user's items, running apps and recent apps into the ordered
/// list of tiles: Finder, the user's items, | running apps that aren't kept,
/// then recent ones, | Trash.
public enum DockContentBuilder {
    public static func build(
        items: [DockItem],
        running: [RunningAppSnapshot],
        recents: [PinnedApp] = [],
        launching: Set<String> = [],
        showRunningApps: Bool = true,
        recentLimit: Int = 0,
        showTrash: Bool = true,
        minimized: [WindowInfo] = []
    ) -> [DockEntry] {
        var runningByKey: [String: RunningAppSnapshot] = [:]
        for app in running where runningByKey[app.key] == nil {
            runningByKey[app.key] = app
        }

        var entries: [DockEntry] = [
            DockEntry(id: DockIdentity.finder, kind: .finder, running: runningByKey[DockIdentity.finder], isLaunching: launching.contains(DockIdentity.finder)),
        ]
        var used: Set<String> = [DockIdentity.finder]

        for item in items where !used.contains(item.id) {
            used.insert(item.id)
            switch item {
            case let .app(pin):
                entries.append(DockEntry(id: pin.id, kind: .pinned(pin), running: runningByKey[pin.id], isLaunching: launching.contains(pin.id)))
            case let .spacer(id):
                entries.append(DockEntry(id: id, kind: .spacer, running: nil, isLaunching: false))
            case let .divider(id, title):
                entries.append(DockEntry(id: id, kind: .divider(title: title), running: nil, isLaunching: false))
            case .share:
                entries.append(DockEntry(id: DockIdentity.share, kind: .share, running: nil, isLaunching: false))
            case let .folder(stack):
                entries.append(DockEntry(id: stack.id, kind: .folder(stack), running: nil, isLaunching: false))
            }
        }

        var extras: [DockEntry] = []
        if showRunningApps {
            for app in running.sorted(by: { $0.order < $1.order }) where !used.contains(app.key) {
                used.insert(app.key)
                extras.append(DockEntry(id: app.key, kind: .running, running: app, isLaunching: launching.contains(app.key)))
            }
        }
        for app in recents where extras.filter(\.isRecent).count < recentLimit {
            guard !used.contains(app.id), runningByKey[app.id] == nil else { continue }
            used.insert(app.id)
            extras.append(DockEntry(id: app.id, kind: .recent(app), running: nil, isLaunching: launching.contains(app.id)))
        }
        if !extras.isEmpty {
            entries.append(DockEntry(id: DockIdentity.runningSeparator, kind: .separator, running: nil, isLaunching: false))
            entries += extras
        }

        // Minimized windows sit with the Trash, as in the macOS Dock.
        let windows = minimized.filter(\.isValid).prefix(WindowInfo.maxCount)
        if showTrash || !windows.isEmpty {
            entries.append(DockEntry(id: DockIdentity.trashSeparator, kind: .separator, running: nil, isLaunching: false))
        }
        for window in windows {
            let id = DockIdentity.window(window)
            guard !used.contains(id) else { continue }
            used.insert(id)
            entries.append(DockEntry(id: id, kind: .window(window), running: nil, isLaunching: false))
        }
        if showTrash {
            entries.append(DockEntry(id: DockIdentity.trash, kind: .trash, running: nil, isLaunching: false))
        }
        return entries
    }

    /// Apps only (no spacers, dividers or Share tile).
    public static func build(
        pins: [PinnedApp],
        running: [RunningAppSnapshot],
        launching: Set<String> = [],
        showRunningApps: Bool = true,
        showTrash: Bool = true
    ) -> [DockEntry] {
        build(items: pins.map(DockItem.app), running: running, launching: launching, showRunningApps: showRunningApps, showTrash: showTrash)
    }
}

extension Array where Element == DockEntry {
    /// The apps that ⌃⌥1 to ⌃⌥9 open: the first nine app tiles, Finder first.
    public var shortcutTargets: [DockEntry] {
        Array(filter(\.isApp).prefix(9))
    }
}
