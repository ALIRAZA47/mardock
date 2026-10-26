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

    func update(_ change: (inout DockSettings) -> Void) {
        var copy = settings
        change(&copy)
        settings = copy
    }
}

/// The apps the user keeps in the dock.
@MainActor
final class PinStore: ObservableObject {
    @Published private(set) var pins: [PinnedApp]
    /// False until the user (or onboarding) has saved a list.
    private(set) var hasSavedList: Bool

    private let defaults: UserDefaults
    private let key = "pins.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = PinnedApp.decodeList(defaults.data(forKey: key)) {
            pins = saved
            hasSavedList = true
        } else {
            pins = Self.defaultPins()
            hasSavedList = false
        }
    }

    func contains(_ id: String) -> Bool { pins.contains { $0.id == id } }

    func setPins(_ newPins: [PinnedApp]) {
        var seen = Set<String>()
        pins = newPins.filter { $0.id != DockIdentity.finder && seen.insert($0.id).inserted }.prefix(PinnedApp.maxCount).map { $0 }
        save()
    }

    func pin(_ app: PinnedApp, at index: Int? = nil) {
        var list = pins.filter { $0.id != app.id }
        let position = min(max(index ?? list.count, 0), list.count)
        list.insert(app, at: position)
        setPins(list)
    }

    func unpin(_ id: String) {
        setPins(pins.filter { $0.id != id })
    }

    func move(_ id: String, to index: Int) {
        guard let app = pins.first(where: { $0.id == id }) else { return }
        pin(app, at: index)
    }

    /// Records a new location for an app that moved on disk.
    func updatePath(of id: String, to path: String) {
        guard let index = pins.firstIndex(where: { $0.id == id }),
              let updated = PinnedApp(bundleIdentifier: pins[index].bundleIdentifier, path: path, name: pins[index].name)
        else { return }
        var list = pins
        list[index] = updated
        setPins(list)
    }

    private func save() {
        hasSavedList = true
        defaults.set(PinnedApp.encodeList(pins), forKey: key)
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
