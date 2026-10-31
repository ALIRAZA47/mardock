import Foundation

/// Decodes one element of a list, or nothing: a bad entry is dropped instead
/// of failing the whole list.
struct Lossy<Element: Decodable>: Decodable {
    var value: Element?

    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}

/// A named set of dock items, such as Work and Personal.
public struct DockProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var items: [DockItem]

    public static let maxCount = 12

    public init(id: String = DockIdentity.newTile(.profile), name: String, items: [DockItem]) {
        self.id = id
        self.name = InputValidation.sanitizedDisplayName(name).isEmpty ? "Profile" : InputValidation.sanitizedDisplayName(name)
        self.items = Array(items.prefix(DockItem.maxCount))
    }

    private enum CodingKeys: String, CodingKey { case id, name, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        guard DockIdentity.isValidTileID(id, kind: .profile) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "Invalid profile"))
        }
        let items = ((try? c.decodeIfPresent([Lossy<DockItem>].self, forKey: .items)) ?? []).compactMap(\.value)
        self.init(id: id, name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "", items: DockItem.unique(items))
    }
}

/// The profiles and which one is in use.
public struct DockProfiles: Codable, Equatable, Sendable {
    public private(set) var profiles: [DockProfile]
    public private(set) var activeID: String

    public init(profiles: [DockProfile], activeID: String?) {
        var seen = Set<String>()
        var list = Array(profiles.filter { seen.insert($0.id).inserted }.prefix(DockProfile.maxCount))
        if list.isEmpty {
            list = [DockProfile(name: "Default", items: [])]
        }
        self.profiles = list
        self.activeID = list.contains { $0.id == activeID } ? activeID! : list[0].id
    }

    public var active: DockProfile { profiles.first { $0.id == activeID } ?? profiles[0] }

    public mutating func setActive(_ id: String) {
        if profiles.contains(where: { $0.id == id }) { activeID = id }
    }

    /// Stores `items` as the items of profile `id`.
    public mutating func setItems(_ items: [DockItem], of id: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].items = Array(DockItem.unique(items).prefix(DockItem.maxCount))
    }

    @discardableResult
    public mutating func add(_ profile: DockProfile) -> Bool {
        guard profiles.count < DockProfile.maxCount, !profiles.contains(where: { $0.id == profile.id }) else { return false }
        profiles.append(profile)
        return true
    }

    public mutating func rename(_ id: String, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let clean = InputValidation.sanitizedDisplayName(name)
        if !clean.isEmpty { profiles[index].name = clean }
    }

    /// Removes a profile (never the last one); the first profile becomes
    /// active if the removed one was.
    public mutating func remove(_ id: String) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = profiles[0].id }
    }

    private enum CodingKeys: String, CodingKey { case profiles, activeID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let profiles = ((try? c.decodeIfPresent([Lossy<DockProfile>].self, forKey: .profiles)) ?? []).compactMap(\.value)
        self.init(profiles: profiles, activeID: try? c.decodeIfPresent(String.self, forKey: .activeID))
    }

    public static func decode(_ data: Data?) -> DockProfiles? {
        guard let data, data.count <= 4 * 1024 * 1024 else { return nil }
        return try? JSONDecoder().decode(DockProfiles.self, from: data)
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

extension DockItem {
    /// Drops repeated ids, keeping the first.
    public static func unique(_ items: [DockItem]) -> [DockItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

/// Everything MarDock keeps, in one file, to move to another Mac or keep as
/// a backup. Reading one never trusts it: every part is validated as if it
/// came from a stranger, and anything invalid is dropped.
public struct MarDockBackup: Sendable {
    public static let format = "io.github.aliraza47.mardock.backup"
    public static let version = 1
    public static let maxBytes = 48 * 1024 * 1024
    public static let maxIcons = 256
    public static let maxIconBytes = 2 * 1024 * 1024
    public static let maxThemes = 64

    public var settings: DockSettings
    public var items: [DockItem]
    public var themes: [ThemeRecipe]
    public var profiles: DockProfiles?
    /// PNG data of custom icons, by app tile id.
    public var icons: [String: Data]
    /// The user's own shortcuts for each app.
    public var userShortcuts: UserShortcutList

    public init(settings: DockSettings, items: [DockItem], themes: [ThemeRecipe], profiles: DockProfiles?, icons: [String: Data], userShortcuts: UserShortcutList = UserShortcutList()) {
        self.settings = settings.sanitized()
        self.items = Array(DockItem.unique(items).prefix(DockItem.maxCount))
        self.themes = Array(themes.filter { !$0.isBuiltIn }.map { $0.sanitized() }.prefix(Self.maxThemes))
        self.profiles = profiles
        self.icons = Self.validIcons(icons)
        self.userShortcuts = userShortcuts
    }

    public enum ReadError: Error, Equatable {
        case tooLarge
        case notABackup
        case newerVersion
    }

    public static func decode(_ data: Data) throws -> MarDockBackup {
        guard data.count <= maxBytes else { throw ReadError.tooLarge }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == format else { throw ReadError.notABackup }
        guard file.version <= version else { throw ReadError.newerVersion }
        return MarDockBackup(
            settings: file.settings ?? DockSettings(),
            items: (file.items ?? []).compactMap(\.value),
            themes: (file.themes ?? []).compactMap(\.value),
            profiles: file.profiles,
            icons: file.icons ?? [:],
            userShortcuts: file.userShortcuts ?? UserShortcutList()
        )
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Output(format: Self.format, version: Self.version, settings: settings, items: items, themes: themes, profiles: profiles, icons: icons, userShortcuts: userShortcuts))
    }

    static func validIcons(_ icons: [String: Data]) -> [String: Data] {
        var result: [String: Data] = [:]
        for (id, png) in icons.sorted(by: { $0.key < $1.key }) where result.count < maxIcons {
            guard id.hasPrefix("app:"), InputValidation.isValidBundleIdentifier(String(id.dropFirst(4))),
                  !png.isEmpty, png.count <= maxIconBytes, png.starts(with: [0x89, 0x50, 0x4E, 0x47])
            else { continue }
            result[id] = png
        }
        return result
    }

    private struct File: Decodable {
        var format: String
        var version: Int
        var settings: DockSettings?
        var items: [Lossy<DockItem>]?
        var themes: [Lossy<ThemeRecipe>]?
        var profiles: DockProfiles?
        var icons: [String: Data]?
        var userShortcuts: UserShortcutList?

        private enum CodingKeys: String, CodingKey { case format, version, settings, items, themes, profiles, icons, userShortcuts }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try c.decode(String.self, forKey: .format)
            version = try c.decode(Int.self, forKey: .version)
            settings = try? c.decodeIfPresent(DockSettings.self, forKey: .settings)
            items = try? c.decodeIfPresent([Lossy<DockItem>].self, forKey: .items)
            themes = try? c.decodeIfPresent([Lossy<ThemeRecipe>].self, forKey: .themes)
            profiles = try? c.decodeIfPresent(DockProfiles.self, forKey: .profiles)
            icons = try? c.decodeIfPresent([String: Data].self, forKey: .icons)
            userShortcuts = try? c.decodeIfPresent(UserShortcutList.self, forKey: .userShortcuts)
        }
    }

    private struct Output: Encodable {
        var format: String
        var version: Int
        var settings: DockSettings
        var items: [DockItem]
        var themes: [ThemeRecipe]
        var profiles: DockProfiles?
        var icons: [String: Data]
        var userShortcuts: UserShortcutList
    }
}
