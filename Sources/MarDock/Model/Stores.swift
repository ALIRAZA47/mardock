import AppKit
import Combine
import MarDockCore

/// User preferences, persisted as one validated JSON blob in the app's own
/// (sandboxed) defaults.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: DockSettings {
        didSet {
            guard settings != oldValue else { return }
            // `encoded()` stores the sanitized form; every consumer sanitizes too.
            defaults.set(settings.encoded(), forKey: Keys.settings)
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let settings = "settings.v1"
        static let onboarded = "onboarding.completed.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = DockSettings.decode(defaults.data(forKey: Keys.settings))
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Keys.onboarded) }
        set { defaults.set(newValue, forKey: Keys.onboarded) }
    }

    /// False until something has changed a setting.
    var hasSavedSettings: Bool { defaults.data(forKey: Keys.settings) != nil }

    func update(_ change: (inout DockSettings) -> Void) {
        var copy = settings
        change(&copy)
        settings = copy
    }
}

/// What the user keeps in the dock, in order: apps, spacers, dividers and
/// the Share tile.
@MainActor
final class PinStore: ObservableObject {
    @Published private(set) var items: [DockItem]
    /// False until the user (or onboarding) has saved a list.
    private(set) var hasSavedList: Bool

    private let defaults: UserDefaults
    private let key = "items.v2"
    /// Before spacers and dividers, only apps were stored.
    private let legacyKey = "pins.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = DockItem.decodeList(defaults.data(forKey: key)) {
            items = saved
            hasSavedList = true
        } else if let legacy = PinnedApp.decodeList(defaults.data(forKey: legacyKey)) {
            items = legacy.map(DockItem.app)
            hasSavedList = true
        } else {
            items = Self.defaultPins().map(DockItem.app)
            hasSavedList = false
        }
    }

    /// The apps among the items.
    var pins: [PinnedApp] { items.compactMap(\.app) }

    func contains(_ id: String) -> Bool { items.contains { $0.id == id } }

    func setItems(_ newItems: [DockItem]) {
        var seen = Set<String>()
        items = newItems.filter { $0.id != DockIdentity.finder && seen.insert($0.id).inserted }.prefix(DockItem.maxCount).map { $0 }
        save()
    }

    /// Replaces everything with these apps.
    func setPins(_ newPins: [PinnedApp]) {
        setItems(newPins.map(DockItem.app))
    }

    /// Adds an item, or moves it if it's already there. `index` counts the
    /// user's items (Finder, running and recent apps aren't among them).
    func insert(_ item: DockItem, at index: Int? = nil) {
        var list = items.filter { $0.id != item.id }
        let position = min(max(index ?? list.count, 0), list.count)
        list.insert(item, at: position)
        setItems(list)
    }

    func pin(_ app: PinnedApp, at index: Int? = nil) {
        insert(.app(app), at: index)
    }

    func remove(_ id: String) {
        setItems(items.filter { $0.id != id })
    }

    func unpin(_ id: String) {
        remove(id)
    }

    func move(_ id: String, to index: Int) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        insert(item, at: index)
    }

    /// Swaps an item for an updated version of itself (same id).
    func replace(_ item: DockItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var list = items
        list[index] = item
        setItems(list)
    }

    func rename(_ id: String, to title: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .divider = items[index] else { return }
        var list = items
        list[index] = .divider(id: id, title: InputValidation.sanitizedDisplayName(title))
        setItems(list)
    }

    /// Records a new location for an app that moved on disk.
    func updatePath(of id: String, to path: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), let app = items[index].app,
              let updated = PinnedApp(bundleIdentifier: app.bundleIdentifier, path: path, name: app.name)
        else { return }
        var list = items
        list[index] = .app(updated)
        setItems(list)
    }

    private func save() {
        hasSavedList = true
        defaults.set(DockItem.encodeList(items), forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    /// A tasteful starting set: Apple apps that exist on this Mac.
    static func defaultPins() -> [PinnedApp] {
        let identifiers = [
            "com.apple.Safari", "com.apple.mail", "com.apple.MobileSMS", "com.apple.Photos",
            "com.apple.Notes", "com.apple.iCal", "com.apple.Music", "com.apple.AppStore",
            "com.apple.systempreferences",
        ]
        return identifiers.compactMap { AppCatalog.pinnedApp(bundleIdentifier: $0) }
    }
}

/// Named sets of dock items, such as Work and Personal. The items of the
/// profile in use live in the PinStore; switching puts them back here and
/// loads the other profile's.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var state: DockProfiles

    private let pins: PinStore
    private let defaults: UserDefaults
    private let key = "profiles.v1"

    init(pins: PinStore, defaults: UserDefaults = .standard) {
        self.pins = pins
        self.defaults = defaults
        state = DockProfiles.decode(defaults.data(forKey: key))
            ?? DockProfiles(profiles: [DockProfile(name: "Default", items: pins.items)], activeID: nil)
    }

    var profiles: [DockProfile] { state.profiles }
    var activeID: String { state.activeID }

    /// Switches the dock to another profile.
    func activate(_ id: String) {
        guard id != state.activeID, state.profiles.contains(where: { $0.id == id }) else { return }
        var updated = snapshot()
        updated.setActive(id)
        state = updated
        pins.setItems(updated.active.items)
        save()
    }

    /// Adds a profile that starts as a copy of the current dock, and uses it.
    @discardableResult
    func create(named name: String) -> String? {
        var updated = snapshot()
        let profile = DockProfile(name: name, items: pins.items)
        guard updated.add(profile) else { return nil }
        state = updated
        save()
        activate(profile.id)
        return profile.id
    }

    func rename(_ id: String, to name: String) {
        var updated = state
        updated.rename(id, to: name)
        state = updated
        save()
    }

    /// Removes a profile (never the last). If it was in use, the dock
    /// switches to the first remaining one.
    func delete(_ id: String) {
        guard state.profiles.count > 1 else { return }
        let wasActive = id == state.activeID
        var updated = snapshot()
        updated.remove(id)
        state = updated
        if wasActive {
            pins.setItems(updated.active.items)
        }
        save()
    }

    /// All profiles, with the one in use as the dock shows it now.
    func snapshot() -> DockProfiles {
        var current = state
        current.setItems(pins.items, of: current.activeID)
        return current
    }

    /// The profile in use before a Focus switched profiles.
    private var beforeFocus: String?

    /// A Focus that uses profile `id` turned on, or (nil) turned off: the
    /// dock goes back to the profile it had before.
    func applyFocus(_ id: String?) {
        if let id {
            guard state.profiles.contains(where: { $0.id == id }) else { return }
            if beforeFocus == nil { beforeFocus = state.activeID }
            activate(id)
        } else if let previous = beforeFocus {
            beforeFocus = nil
            activate(previous)
        }
    }

    /// Replaces every profile (importing a backup).
    func replace(with profiles: DockProfiles) {
        state = profiles
        pins.setItems(profiles.active.items)
        save()
    }

    private func save() {
        defaults.set(state.encoded(), forKey: key)
    }
}

/// Asks for a profile's name; nil if the user cancels. The name may be empty.
@MainActor
func askForProfileName(title: String, button: String, initial: String, detail: String? = nil) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    if let detail { alert.informativeText = detail }
    let field = NSTextField(string: initial)
    field.placeholderString = "Work, Personal, Games…"
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Apps used recently, for the dock's recent section. Only apps the user
/// brings to the front count, and only their name and location are kept.
@MainActor
final class RecentAppsStore: ObservableObject {
    @Published private(set) var recents: RecentApps

    private let defaults: UserDefaults
    private let key = "recents.v1"
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recents = RecentApps(PinnedApp.decodeList(defaults.data(forKey: key)) ?? [])
    }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.note(app) }
        }
    }

    func note(_ app: NSRunningApplication?) {
        guard let app, app.activationPolicy == .regular, let identifier = app.bundleIdentifier,
              identifier.lowercased() != DockIdentity.finderBundleIdentifier, let url = app.bundleURL,
              let recent = PinnedApp(bundleIdentifier: identifier, path: url.path, name: app.localizedName ?? "")
        else { return }
        var updated = recents
        updated.note(recent)
        save(updated)
    }

    func remove(_ id: String) {
        var updated = recents
        updated.remove(id)
        save(updated)
    }

    private func save(_ updated: RecentApps) {
        guard updated != recents else { return }
        recents = updated
        defaults.set(PinnedApp.encodeList(updated.apps), forKey: key)
    }
}

/// The user's own shortcuts for each app, shown on its shortcuts panel.
@MainActor
final class UserShortcutStore: ObservableObject {
    @Published private(set) var list: UserShortcutList

    private let defaults: UserDefaults
    private let key = "userShortcuts.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        list = UserShortcutList.decode(defaults.data(forKey: key))
    }

    func shortcuts(forApp bundleIdentifier: String) -> [UserShortcut] {
        list.shortcuts(forApp: bundleIdentifier)
    }

    func add(_ shortcut: UserShortcut, toApp bundleIdentifier: String) {
        var updated = list
        updated.add(shortcut, toApp: bundleIdentifier)
        replace(with: updated)
    }

    func remove(_ id: String, fromApp bundleIdentifier: String) {
        var updated = list
        updated.remove(id, fromApp: bundleIdentifier)
        replace(with: updated)
    }

    func replace(with updated: UserShortcutList) {
        list = updated
        defaults.set(updated.encoded(), forKey: key)
    }

    /// The file or folder the user just chose, remembered as a bookmark.
    static func action(forFile url: URL) -> UserShortcut.Action? {
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }
        return .file(path: url.path, bookmark: bookmark)
    }
}

/// Icons the user picked for apps, kept as PNG files inside MarDock's own
/// sandbox container. Whatever the user drops is decoded and redrawn here, so
/// only images MarDock rendered itself are ever stored.
@MainActor
final class CustomIconStore: ObservableObject {
    /// Changes whenever an icon is added or removed.
    @Published private(set) var revision = 0

    private let directory: URL?
    private var cache: [String: NSImage] = [:]
    private var known: Set<String> = []

    static let maxSourceBytes = 25 * 1024 * 1024
    static let storedPixels = 512

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        directory = base?.appendingPathComponent("Icons", isDirectory: true)
        if let directory, let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            known = Set(files.compactMap(Self.id(forFileName:)))
        }
    }

    func hasIcon(for id: String) -> Bool { known.contains(id) }

    /// The tiles that have a custom icon.
    var iconIDs: [String] { known.sorted() }

    /// The stored PNG, for backups.
    func pngData(for id: String) -> Data? {
        guard known.contains(id), let url = fileURL(for: id) else { return nil }
        return try? Data(contentsOf: url)
    }

    func icon(for id: String) -> NSImage? {
        guard known.contains(id) else { return nil }
        if let cached = cache[id] { return cached }
        guard let url = fileURL(for: id), let image = NSImage(contentsOf: url) else { return nil }
        cache[id] = image
        return image
    }

    /// Uses the image in `url` (dropped or chosen by the user) for tile `id`.
    func setIcon(contentsOf url: URL, for id: String) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard url.isFileURL, size > 0, size <= Self.maxSourceBytes,
              let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0, image.size.height > 0
        else { throw CustomIconError.unreadable }
        try setIcon(image, for: id)
    }

    func setIcon(_ image: NSImage, for id: String) throws {
        guard let destination = fileURL(for: id), let directory,
              let rendered = IconProvider.render(image, pixels: Self.storedPixels),
              let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])
        else { throw CustomIconError.unreadable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: destination, options: .atomic)
        cache[id] = nil
        known.insert(id)
        revision += 1
    }

    func removeIcon(for id: String) {
        guard known.contains(id), let url = fileURL(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
        cache[id] = nil
        known.remove(id)
        revision += 1
    }

    /// `app:com.example.app` is stored as `app_com.example.app.png`. Only app
    /// tiles have custom icons, and their ids are already filename-safe.
    private func fileURL(for id: String) -> URL? {
        guard let directory, id.hasPrefix("app:"),
              InputValidation.isValidBundleIdentifier(String(id.dropFirst(4)))
        else { return nil }
        return directory.appendingPathComponent("app_" + id.dropFirst(4) + ".png")
    }

    private static func id(forFileName name: String) -> String? {
        guard name.hasPrefix("app_"), name.hasSuffix(".png") else { return nil }
        let identifier = String(name.dropFirst(4).dropLast(4))
        return InputValidation.isValidBundleIdentifier(identifier) ? "app:" + identifier : nil
    }
}

enum CustomIconError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "That file isn't an image MarDock can use."
    }
}

/// Themes the user made in the theme editor or loaded from files.
@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var custom: [ThemeRecipe]

    private let defaults: UserDefaults
    private let key = "themes.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        custom = ThemeRecipe.decodeList(defaults.data(forKey: key))
    }

    /// The theme the settings ask for: the user's own while it exists,
    /// otherwise the built-in one.
    func recipe(for settings: DockSettings) -> ThemeRecipe {
        if let id = settings.customTheme, let theme = theme(withID: id) {
            return theme
        }
        return .builtIn(settings.theme)
    }

    func theme(withID id: String) -> ThemeRecipe? {
        custom.first { $0.id == id }
    }

    /// Adds a theme, or replaces the one with the same id.
    func save(_ recipe: ThemeRecipe) {
        let clean = recipe.sanitized()
        guard !clean.isBuiltIn else { return }
        var list = custom
        if let index = list.firstIndex(where: { $0.id == clean.id }) {
            list[index] = clean
        } else {
            list.append(clean)
        }
        set(list)
    }

    func delete(_ id: String) {
        set(custom.filter { $0.id != id })
    }

    /// Reads a theme file. One that would replace a theme already here
    /// comes in as a copy instead.
    @discardableResult
    func importTheme(from url: URL) throws -> ThemeRecipe {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= ThemeRecipe.maxFileBytes, let data = try? Data(contentsOf: url),
              var recipe = ThemeRecipe.decode(data)
        else { throw ThemeFileError.unreadable }
        if recipe.isBuiltIn || theme(withID: recipe.id) != nil {
            recipe = recipe.duplicate(named: recipe.name)
        }
        save(recipe)
        return recipe
    }

    func export(_ recipe: ThemeRecipe, to url: URL) throws {
        guard let data = recipe.encoded() else { throw ThemeFileError.unreadable }
        try data.write(to: url, options: .atomic)
    }

    private func set(_ list: [ThemeRecipe]) {
        custom = Array(list.prefix(ThemeRecipe.maxCustomThemes))
        defaults.set(ThemeRecipe.encodeList(custom), forKey: key)
    }
}

enum ThemeFileError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "That file isn't a MarDock theme."
    }
}

/// Looks apps up through Launch Services (works inside the sandbox).
@MainActor
enum AppCatalog {
    static func pinnedApp(bundleIdentifier: String) -> PinnedApp? {
        guard InputValidation.isValidBundleIdentifier(bundleIdentifier),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return nil }
        return PinnedApp(bundleIdentifier: bundleIdentifier, path: url.path, name: displayName(for: url))
    }

    /// Builds a pin from an app bundle URL (dropped or chosen in an open panel).
    static func pinnedApp(url: URL) -> PinnedApp? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier
        else { return nil }
        return PinnedApp(bundleIdentifier: identifier, path: url.path, name: displayName(for: url))
    }

    static func displayName(for url: URL) -> String {
        var name = FileManager.default.displayName(atPath: url.path)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        return InputValidation.sanitizedDisplayName(name)
    }
}
