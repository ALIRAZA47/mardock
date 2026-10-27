import AppKit
import Combine
import MarDockCore
import SwiftUI

/// Builds the object graph and owns the app's windows.
@MainActor
final class AppCoordinator: NSObject, ObservableObject {
    /// The running app's coordinator, for Shortcuts actions.
    private(set) static weak var current: AppCoordinator?

    let settings = SettingsStore()
    let pins = PinStore()
    let profiles: ProfileStore
    let recents = RecentAppsStore()
    let customIcons = CustomIconStore()
    let themes = ThemeStore()
    let folders = FolderStacks()
    let running = RunningAppsMonitor()
    let icons = IconProvider()
    let shortcuts = LaunchShortcuts()
    let agent = AgentClient()
    let loginItem = LoginItemManager()
    let systemDock: SystemDockManager
    let actions: AppActions
    let extras: ExtrasMonitor
    let dock: DockController
    let security: SecurityStatus

    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var isPoweringOff = false
    private var powerObserver: NSObjectProtocol?

    override init() {
        profiles = ProfileStore(pins: pins)
        systemDock = SystemDockManager(agent: agent)
        actions = AppActions(agent: agent, pins: pins)
        extras = ExtrasMonitor(agent: agent, settings: settings)
        dock = DockController(
            settings: settings, pins: pins, recents: recents, customIcons: customIcons, themes: themes, folders: folders,
            running: running, icons: icons, actions: actions, systemDock: systemDock, extras: extras
        )
        security = SecurityStatus(agent: agent)
        super.init()
        icons.customIcons = customIcons
        icons.folders = folders
        dock.coordinator = self
        Self.current = self
    }

    func start() {
        running.start()
        recents.start()
        extras.start()
        dock.start()
        shortcuts.onPress = { [weak self] index in self?.dock.openShortcutTarget(index) }
        settings.$settings
            .map(\.launchShortcut)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shortcut in self?.shortcuts.update(shortcut) }
            .store(in: &cancellables)
        statusItem = StatusItemController(coordinator: self)
        installMainMenu()

        // Siri and Spotlight phrases name profiles and themes.
        MarDockShortcuts.updateAppShortcutParameters()
        profiles.$state.map(\.profiles).removeDuplicates().dropFirst().map { _ in () }
            .merge(with: themes.$custom.removeDuplicates().dropFirst().map { _ in () })
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { _ in MarDockShortcuts.updateAppShortcutParameters() }
            .store(in: &cancellables)

        powerObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPoweringOff = true }
        }

        // Keep the macOS Dock in the state the user chose.
        settings.$settings
            .map(\.hideSystemDock)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] hide in self?.syncSystemDock(hide: hide) }
            .store(in: &cancellables)

        if settings.hasCompletedOnboarding {
            syncSystemDock(hide: settings.settings.hideSystemDock)
        } else {
            showWelcome()
        }
    }

    private func syncSystemDock(hide: Bool) {
        Task {
            if hide {
                await systemDock.hide()
            } else if systemDock.isHiddenByMarDock {
                await systemDock.restore()
            } else {
                await systemDock.refresh()
            }
        }
    }

    /// Restores the macOS Dock on quit (unless the Mac is shutting down or
    /// logging out, in which case MarDock will hide it again at next login).
    func prepareForTermination(_ done: @escaping @MainActor () -> Void) {
        let s = settings.settings
        guard s.hideSystemDock, s.restoreSystemDockOnQuit, !isPoweringOff, systemDock.isHiddenByMarDock else {
            done()
            return
        }
        let gate = OneShot(done)
        Task {
            await systemDock.restore()
            gate.fire()
        }
        // Never hang the quit on a stuck helper.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { gate.fire() }
        }
    }

    /// MarDock has no Dock icon, but while its Settings window is in front
    /// the menu bar should still offer the usual commands and shortcuts.
    private func installMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu(title: "MarDock")
        appMenu.addItem(ClosureMenuItem("About MarDock") { [weak self] in self?.showAbout() })
        appMenu.addItem(.separator())
        let settingsItem = ClosureMenuItem("Settings…") { [weak self] in self?.showSettings() }
        settingsItem.keyEquivalent = ","
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide MarDock", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit MarDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Onboarding

    /// Called when the welcome screen finishes.
    func completeOnboarding(importDock: Bool, hideSystemDock: Bool, openAtLogin: Bool) {
        settings.hasCompletedOnboarding = true
        welcomeWindow?.close()
        welcomeWindow = nil
        if openAtLogin != loginItem.isEnabled {
            loginItem.setEnabled(openAtLogin)
        }
        Task {
            if importDock {
                await importFromSystemDock()
            }
            // Changing the setting triggers the sync; if it didn't change, sync explicitly.
            let changed = settings.settings.hideSystemDock != hideSystemDock
            settings.update { $0.hideSystemDock = hideSystemDock }
            if !changed {
                syncSystemDock(hide: hideSystemDock)
            }
        }
    }

    /// Replaces the pinned apps with the ones in the macOS Dock.
    @discardableResult
    func importFromSystemDock() async -> Int {
        do {
            let imported = try await agent.importSystemDockApps()
            let apps = imported.compactMap { PinnedApp(bundleIdentifier: $0.bundleIdentifier, path: $0.path, name: $0.name) }
            guard !apps.isEmpty else { return 0 }
            pins.setPins(apps)
            return apps.count
        } catch {
            appLog.error("Import failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    // MARK: - Backup

    /// Everything MarDock keeps, for Export Settings.
    func makeBackup() -> MarDockBackup {
        var icons: [String: Data] = [:]
        for id in customIcons.iconIDs {
            icons[id] = customIcons.pngData(for: id)
        }
        return MarDockBackup(settings: settings.settings, items: pins.items, themes: themes.custom, profiles: profiles.snapshot(), icons: icons)
    }

    /// Replaces the dock, settings, themes and icons with a backup's. Choices
    /// that belong to this Mac (the macOS Dock, which display) stay as they are.
    func apply(_ backup: MarDockBackup) {
        for theme in backup.themes {
            themes.save(theme)
        }
        let local = settings.settings
        var incoming = backup.settings
        incoming.hideSystemDock = local.hideSystemDock
        incoming.restoreSystemDockOnQuit = local.restoreSystemDockOnQuit
        incoming.display = local.display
        settings.settings = incoming.sanitized()
        if let saved = backup.profiles {
            profiles.replace(with: saved)
        } else {
            pins.setItems(backup.items)
        }
        for (id, png) in backup.icons {
            if let image = NSImage(data: png) {
                try? customIcons.setIcon(image, for: id)
            }
        }
    }

    // MARK: - Windows

    func showSettings() {
        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(self)
                .environmentObject(settings)
                .environmentObject(pins)
                .environmentObject(profiles)
                .environmentObject(extras)
                .environmentObject(customIcons)
                .environmentObject(themes)
                .environmentObject(systemDock)
                .environmentObject(loginItem)
                .environmentObject(security)
            let window = makeWindow(title: "MarDock Settings", size: NSSize(width: 820, height: 600), content: root)
            window.setFrameAutosaveName("MarDockSettings")
            settingsWindow = window
        }
        present(settingsWindow)
    }

    func showWelcome() {
        if welcomeWindow == nil {
            let root = WelcomeView()
                .environmentObject(self)
                .environmentObject(settings)
                .environmentObject(loginItem)
            let window = makeWindow(title: "Welcome to MarDock", size: NSSize(width: 720, height: 640), content: root)
            window.styleMask.remove(.resizable)
            welcomeWindow = window
        }
        present(welcomeWindow)
    }

    func showAbout() {
        showSettings(pane: .about)
    }

    /// Opens Settings on one of its panes.
    func showSettings(pane: SettingsView.Pane) {
        showSettings()
        NotificationCenter.default.post(name: .showSettingsPane, object: pane.rawValue)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: min(size.width, 720), height: min(size.height, 520))
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// Runs a closure at most once.
@MainActor
final class OneShot {
    private var action: (@MainActor () -> Void)?

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func fire() {
        let pending = action
        action = nil
        pending?()
    }
}

extension Notification.Name {
    /// Settings switches to the pane whose raw value is the notification's object.
    static let showSettingsPane = Notification.Name("MarDock.showSettingsPane")
}

/// What the Privacy & Security pane shows, gathered from the system itself
/// rather than asserted.
@MainActor
final class SecurityStatus: ObservableObject {
    struct Snapshot {
        var sandboxed: Bool
        var networkEntitled: Bool
        var signature: CodeSignatureInfo
    }

    @Published private(set) var snapshot: Snapshot
    @Published private(set) var helper: AgentInfo?
    @Published private(set) var helperError: String?
    @Published private(set) var integrity: IntegrityReport?
    @Published private(set) var isVerifying = false

    private let agent: AgentClient

    init(agent: AgentClient) {
        self.agent = agent
        snapshot = Snapshot(
            sandboxed: ProcessSecurity.isSandboxed,
            networkEntitled: ProcessSecurity.hasEntitlement("com.apple.security.network.client")
                || ProcessSecurity.hasEntitlement("com.apple.security.network.server"),
            signature: CodeSignature.inspectSelf()
        )
    }

    func refreshHelper() async {
        do {
            helper = try await agent.hello()
            helperError = nil
        } catch {
            helper = nil
            helperError = error.localizedDescription
        }
    }

    func verify() async {
        isVerifying = true
        defer { isVerifying = false }
        do {
            integrity = try await agent.verifyIntegrity()
            helperError = nil
        } catch {
            helperError = error.localizedDescription
        }
    }
}
