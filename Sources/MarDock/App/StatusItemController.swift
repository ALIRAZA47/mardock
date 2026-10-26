import AppKit
import MarDockCore

/// MarDock's menu bar item. MarDock is an agent app (no Dock icon of its
/// own), so this is how you reach Settings or quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var coordinator: AppCoordinator?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
        if let button = item.button {
            let image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "MarDock")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "MarDock"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let coordinator else { return }
        let header = NSMenuItem(title: "MarDock", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let dock = coordinator.dock
        menu.addItem(ClosureMenuItem("Show MarDock", symbol: "dock.rectangle", state: dock.isVisible ? .on : .off) { [weak dock] in
            guard let dock else { return }
            dock.setVisible(!dock.isVisible)
        })

        let settings = coordinator.settings
        let hideTitle = "Hide the macOS Dock"
        menu.addItem(ClosureMenuItem(hideTitle, symbol: "dock.arrow.down.rectangle", state: settings.settings.hideSystemDock ? .on : .off) { [weak settings] in
            settings?.update { $0.hideSystemDock.toggle() }
        })
        if coordinator.systemDock.isHiddenByMarDock || coordinator.systemDock.looksHidden {
            menu.addItem(ClosureMenuItem("Restore the macOS Dock", symbol: "arrow.uturn.backward") { [weak coordinator] in
                guard let coordinator else { return }
                if coordinator.settings.settings.hideSystemDock {
                    // Turning the setting off restores it.
                    coordinator.settings.update { $0.hideSystemDock = false }
                } else {
                    Task { await coordinator.systemDock.restore() }
                }
            })
        }

        menu.addItem(.separator())
        let settingsItem = ClosureMenuItem("Settings…", symbol: "gearshape") { [weak coordinator] in
            coordinator?.showSettings()
        }
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(ClosureMenuItem("About MarDock", symbol: "info.circle") { [weak coordinator] in
            coordinator?.showAbout()
        })
        menu.addItem(.separator())
        let quit = ClosureMenuItem("Quit MarDock", symbol: "power") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }
}
