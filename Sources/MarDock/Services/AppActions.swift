import AppKit
import MarDockCore
import ServiceManagement

/// Everything the dock can do to apps. Launching, activating and hiding go
/// through public NSWorkspace / NSRunningApplication APIs; quitting goes
/// through the helper, because the sandbox (correctly) forbids it here.
@MainActor
final class AppActions {
    private let agent: AgentClient
    private let pins: PinStore

    init(agent: AgentClient, pins: PinStore) {
        self.agent = agent
        self.pins = pins
    }

    /// Where the app for a tile lives, re-resolving pins whose app moved.
    func appURL(for entry: DockEntry, running: NSRunningApplication?) -> URL? {
        if let url = running?.bundleURL { return url }
        switch entry.kind {
        case .finder:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: DockIdentity.finderBundleIdentifier)
        case let .pinned(pin), let .recent(pin):
            if FileManager.default.fileExists(atPath: pin.path) {
                return URL(fileURLWithPath: pin.path, isDirectory: true)
            }
            if let moved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pin.bundleIdentifier) {
                if entry.isPinned {
                    pins.updatePath(of: pin.id, to: moved.path)
                }
                return moved
            }
            return nil
        case .running:
            return nil
        case .separator, .trash, .spacer, .divider, .share, .folder, .window:
            return nil
        }
    }

    /// Opens (or brings forward) an app the way the Dock does: through Launch
    /// Services, which also reopens a window if the app has none.
    func open(_ entry: DockEntry, running: NSRunningApplication?, completion: @escaping @MainActor (Bool) -> Void) {
        guard let url = appURL(for: entry, running: running) else {
            if let running {
                completion(running.activate())
            } else {
                completion(false)
            }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            let succeeded = app != nil && error == nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(succeeded) }
            }
        }
    }

    /// Opens documents dropped on a tile with that tile's app.
    func open(documents: [URL], with entry: DockEntry, running: NSRunningApplication?) {
        guard !documents.isEmpty, let url = appURL(for: entry, running: running) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(documents, withApplicationAt: url, configuration: configuration, completionHandler: nil)
    }

    func revealInFinder(_ entry: DockEntry, running: NSRunningApplication?) {
        guard let url = appURL(for: entry, running: running) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Hides or shows an app. Asks directly first; if the sandbox gets in the
    /// way (the app's state hasn't changed shortly after), asks the helper.
    func setHidden(_ app: NSRunningApplication, _ hidden: Bool) {
        _ = hidden ? app.hide() : app.unhide()
        guard let identifier = app.bundleIdentifier else { return }
        let pid = app.processIdentifier
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard app.isHidden != hidden, !app.isTerminated else { return }
            do {
                try await agent.setHidden(pid: pid, bundleIdentifier: identifier, hidden: hidden)
            } catch {
                appLog.error("Hide via helper failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func hide(_ app: NSRunningApplication) { setHidden(app, true) }
    func unhide(_ app: NSRunningApplication) { setHidden(app, false) }

    func quit(_ app: NSRunningApplication, force: Bool) async throws {
        guard let identifier = app.bundleIdentifier else { throw AgentClientError.refused(.notAllowed) }
        try await agent.quit(pid: app.processIdentifier, bundleIdentifier: identifier, force: force)
    }

    /// Brings back a minimized window (through the helper, which needs
    /// Accessibility).
    func showWindow(_ window: WindowInfo, completion: @escaping @MainActor (Bool) -> Void) {
        Task {
            do {
                try await agent.showWindow(window)
                completion(true)
            } catch {
                appLog.error("Couldn't bring the window back: \(error.localizedDescription, privacy: .public)")
                completion(false)
            }
        }
    }

    func openTrash() {
        Task {
            do {
                try await agent.openTrash()
            } catch {
                appLog.error("Couldn't open the Trash: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }
}

/// "Open at login", via the modern ServiceManagement API (no helper needed).
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
