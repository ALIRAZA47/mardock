import Foundation

/// What double-clicking an app in the dock does.
public enum DoubleClickAction: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The app's shortcuts, in a panel above its tile.
    case shortcuts
    case hide
    case hideOthers
    case off

    public var id: String { rawValue }
}

/// What a click on a dock tile does, once it's known whether it might be
/// half of a double-click.
public enum DockClick: Equatable, Sendable {
    /// What a click does now.
    case activate
    /// The same, after the double-click interval, unless a second click comes.
    case activateUnlessDoubled
    case doubleClick
    /// A third click or more.
    case ignore

    /// `hidesOnClick`: this click would hide the frontmost app. Nothing else
    /// has to wait: the first click of a double-click opens the app or brings
    /// it forward, which the second doesn't undo.
    public static func decide(isApp: Bool, action: DoubleClickAction, hasModifiers: Bool, clickCount: Int, hidesOnClick: Bool) -> DockClick {
        guard isApp, action != .off, !hasModifiers else { return .activate }
        switch clickCount {
        case 2: return .doubleClick
        case 1: return hidesOnClick ? .activateUnlessDoubled : .activate
        default: return .ignore
        }
    }
}

/// A shortcut the user made for an app: a website or a file to open in it,
/// or one of their Shortcuts to run.
public struct UserShortcut: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Action: Codable, Equatable, Hashable, Sendable {
        case website(URL)
        /// A file or folder the user chose, remembered with a read-only
        /// security-scoped bookmark.
        case file(path: String, bookmark: Data)
        /// A shortcut from the Shortcuts app, by name.
        case shortcut(String)
    }

    public var id: String
    public var title: String
    public var action: Action

    public static let maxTitleLength = 60
    public static let maxBookmarkBytes = 16 * 1024

    public init?(id: String = UUID().uuidString.lowercased(), title: String, action: Action) {
        let clean = String(InputValidation.sanitizedDisplayName(title).prefix(Self.maxTitleLength))
        guard !id.isEmpty, id.utf8.count <= 64, !clean.isEmpty, Self.isValid(action) else { return nil }
        self.id = id
        self.title = clean
        self.action = action
    }

    /// Only websites and mail: a file that came from someone else must not
    /// be able to put a `file:` or app-launching link on the panel.
    public static func webURL(from text: String) -> URL? {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty, string.utf8.count <= 2048 else { return nil }
        if !hasScheme(string) {
            string = "https://" + string
        }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return url.host?.isEmpty == false ? url : nil
        case "mailto": return url
        default: return nil
        }
    }

    /// Whether `text` starts with a scheme of its own, decided here rather
    /// than left to how `URL` reads what comes after "https://": a colon
    /// before any slash, unless a port follows it, as in `localhost:3000`.
    private static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") else { return false }
        let port = text[text.index(after: colon)...].prefix { $0 != "/" }
        return port.isEmpty || !port.allSatisfy(\.isNumber)
    }

    private static func isValid(_ action: Action) -> Bool {
        switch action {
        case let .website(url):
            return webURL(from: url.absoluteString) == url
        case let .file(path, bookmark):
            return InputValidation.isPlausibleAbsolutePath(path) && !bookmark.isEmpty && bookmark.count <= maxBookmarkBytes
        case let .shortcut(name):
            return !InputValidation.sanitizedDisplayName(name).isEmpty
        }
    }

    private enum CodingKeys: String, CodingKey { case id, title, action }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let valid = UserShortcut(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            action: try c.decode(Action.self, forKey: .action)
        ) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Invalid shortcut"))
        }
        self = valid
    }
}

/// The user's shortcuts, by app. Keys are bundle identifiers in lower case,
/// as tile ids are, so a tile finds its own.
public struct UserShortcutList: Codable, Equatable, Sendable {
    public private(set) var byApp: [String: [UserShortcut]]

    public static let maxApps = 128
    public static let maxPerApp = 12

    public init() {
        byApp = [:]
    }

    public func shortcuts(forApp bundleIdentifier: String) -> [UserShortcut] {
        byApp[bundleIdentifier.lowercased()] ?? []
    }

    /// The apps that have shortcuts.
    public var apps: [String] { byApp.keys.sorted() }

    public mutating func add(_ shortcut: UserShortcut, toApp bundleIdentifier: String) {
        let key = bundleIdentifier.lowercased()
        guard InputValidation.isValidBundleIdentifier(key), byApp[key] != nil || byApp.count < Self.maxApps else { return }
        var list = byApp[key] ?? []
        guard list.count < Self.maxPerApp, !list.contains(where: { $0.id == shortcut.id }) else { return }
        list.append(shortcut)
        byApp[key] = list
    }

    public mutating func remove(_ id: String, fromApp bundleIdentifier: String) {
        let key = bundleIdentifier.lowercased()
        guard var list = byApp[key] else { return }
        list.removeAll { $0.id == id }
        byApp[key] = list.isEmpty ? nil : list
    }

    private enum CodingKeys: String, CodingKey { case byApp }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stored = (try? c.decodeIfPresent([String: [Lossy<UserShortcut>]].self, forKey: .byApp)) ?? [:]
        var list = UserShortcutList()
        for (app, shortcuts) in stored.sorted(by: { $0.key < $1.key }) {
            for shortcut in shortcuts.compactMap(\.value) {
                list.add(shortcut, toApp: app)
            }
        }
        self = list
    }

    public static func decode(_ data: Data?) -> UserShortcutList {
        guard let data, data.count <= 1024 * 1024, let list = try? JSONDecoder().decode(UserShortcutList.self, from: data) else {
            return UserShortcutList()
        }
        return list
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

/// A command from an app's own File menu, as the shortcuts panel shows it.
public struct AppCommand: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var title: String
    /// Its keyboard shortcut as menus write it, such as ⇧⌘N. Empty if none.
    public var keys: String
    /// The submenu it's in, such as Terminal's New Window. Empty if none.
    public var submenu: String

    public static let maxTitleLength = 80
    public static let maxKeysLength = 8

    public init(title: String, keys: String = "", submenu: String = "") {
        self.title = String(InputValidation.sanitizedDisplayName(title).prefix(Self.maxTitleLength))
        self.keys = String(keys.prefix(Self.maxKeysLength))
        self.submenu = String(InputValidation.sanitizedDisplayName(submenu).prefix(Self.maxTitleLength))
    }

    public var id: String { submenu + "\u{1F}" + title }

    public var isValid: Bool {
        !title.isEmpty && title.count <= Self.maxTitleLength && keys.count <= Self.maxKeysLength && submenu.count <= Self.maxTitleLength
    }
}

/// Which menu items MarDock offers. The helper applies this both when it
/// lists an app's commands and again when told to choose one, so the app can
/// only ever have it open or create something, never press Delete, Quit or
/// anything else in another app's menus, however it asks.
public enum AppCommandFilter {
    /// At most this many commands go on the panel.
    public static let maxCount = 8

    /// The menu to read, in the order the menu bar has them: the Apple menu,
    /// the app's own, then File (Shell in Terminal). By position, because
    /// the title changes with the language.
    public static let menuIndex = 2

    /// AXMenuItemCmdModifiers: nothing set means ⌘ alone.
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let control = Modifiers(rawValue: 4)
        public static let noCommand = Modifiers(rawValue: 8)
    }

    private static let creating = ["new", "open", "reopen"]
    private static let refused = ["close", "quit", "delete", "remove", "erase", "trash", "uninstall", "log out", "sign out", "restart", "shut down"]
    private static let creatingKeys: Set<String> = ["N", "T", "O"]

    private static func words(of title: String) -> [String] {
        title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Whether a menu item may be offered: its title starts with New or Open,
    /// or (for apps in other languages) it has the usual shortcut for those,
    /// and nothing in its title says it does something else.
    public static func isOffered(title: String, key: String?, modifiers: Int?) -> Bool {
        let titleWords = words(of: title)
        let spaced = " " + titleWords.joined(separator: " ") + " "
        guard let first = titleWords.first, !refused.contains(where: { spaced.contains(" \($0) ") }) else { return false }
        if creating.contains(first) { return true }
        guard let key, creatingKeys.contains(key.uppercased()) else { return false }
        return Modifiers(rawValue: modifiers ?? 0).isDisjoint(with: [.noCommand, .control])
    }

    /// Whether a submenu's contents may be read. Only for New: others, such
    /// as Open Recent, list the user's files.
    public static func listsNewItems(_ title: String) -> Bool {
        words(of: title).first == "new"
    }

    /// A menu item's shortcut as menus write it. Keys that have no character
    /// (function keys and the like) show nothing.
    public static func keys(key: String?, modifiers: Int?) -> String {
        guard let key, key.count == 1, let scalar = key.unicodeScalars.first, scalar.value >= 0x21, scalar.value < 0xF700 else { return "" }
        let flags = Modifiers(rawValue: modifiers ?? 0)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if !flags.contains(.noCommand) { text += "⌘" }
        return text + key.uppercased()
    }
}
