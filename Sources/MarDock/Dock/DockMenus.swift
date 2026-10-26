import AppKit
import MarDockCore

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.state = state
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

/// Context menus for tiles and for the dock itself.
@MainActor
enum DockMenus {
    static func menu(for entry: DockEntry, controller: DockController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: controller.name(for: entry.id), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        switch entry.kind {
        case .trash:
            menu.addItem(ClosureMenuItem("Open", symbol: "trash") { [weak controller] in
                controller?.activate(entry, modifiers: [])
            })
            return menu
        case .separator:
            return menu
        default:
            break
        }

        let app = controller.runningApp(for: entry)
        if let app {
            menu.addItem(ClosureMenuItem("Show", symbol: "macwindow") { [weak controller] in
                controller?.activate(entry, modifiers: [])
            })
            if app.isHidden {
                menu.addItem(ClosureMenuItem("Unhide", symbol: "eye") { app.unhide() })
            } else {
                menu.addItem(ClosureMenuItem("Hide", symbol: "eye.slash") { app.hide() })
            }
        } else {
            menu.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { [weak controller] in
                controller?.activate(entry, modifiers: [])
            })
        }
        menu.addItem(ClosureMenuItem("Show in Finder", symbol: "folder") { [weak controller] in
            controller?.activate(entry, modifiers: .command)
        })

        switch entry.kind {
        case .pinned:
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Remove from Dock", symbol: "minus.circle") { [weak controller] in
                controller?.unpin(entry)
            })
        case .running where controller.pinnable(entry) != nil:
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Keep in Dock", symbol: "pin") { [weak controller] in
                controller?.keepInDock(entry)
            })
        default:
            break
        }

        if let app, entry.kind != .finder, app.bundleIdentifier != nil {
            menu.addItem(.separator())
            let quit = ClosureMenuItem("Quit", symbol: "xmark.circle") { [weak controller] in
                controller?.quit(app, force: false)
            }
            quit.keyEquivalentModifierMask = []
            let forceQuit = ClosureMenuItem("Force Quit", symbol: "exclamationmark.octagon") { [weak controller] in
                controller?.quit(app, force: true)
            }
            forceQuit.keyEquivalentModifierMask = .option
            forceQuit.isAlternate = true
            menu.addItem(quit)
            menu.addItem(forceQuit)
        }
        return menu
    }

    static func dockMenu(controller: DockController, settings: SettingsStore, coordinator: AppCoordinator?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let s = settings.settings

        let themes = NSMenu()
        for theme in ThemeID.allCases {
            themes.addItem(ClosureMenuItem(theme.displayName, state: s.theme == theme ? .on : .off) { [weak settings] in
                settings?.update { $0.theme = theme }
            })
        }
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        themeItem.submenu = themes
        menu.addItem(themeItem)

        let positions = NSMenu()
        for (position, title) in [(DockPosition.left, "Left"), (.bottom, "Bottom"), (.right, "Right")] {
            positions.addItem(ClosureMenuItem(title, state: s.position == position ? .on : .off) { [weak settings] in
                settings?.update { $0.position = position }
            })
        }
        let positionItem = NSMenuItem(title: "Position on Screen", action: nil, keyEquivalent: "")
        positionItem.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: nil)
        positionItem.submenu = positions
        menu.addItem(positionItem)

        let hiding = NSMenu()
        for (mode, title) in [(AutoHideMode.off, "Never"), (.always, "Always"), (.smart, "When a Window Overlaps")] {
            hiding.addItem(ClosureMenuItem(title, state: s.autoHide == mode ? .on : .off) { [weak settings] in
                settings?.update { $0.autoHide = mode }
            })
        }
        let hidingItem = NSMenuItem(title: "Automatically Hide", action: nil, keyEquivalent: "")
        hidingItem.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        hidingItem.submenu = hiding
        menu.addItem(hidingItem)

        menu.addItem(ClosureMenuItem("Magnification", symbol: "plus.magnifyingglass", state: s.magnificationEnabled ? .on : .off) { [weak settings] in
            settings?.update { $0.magnificationEnabled.toggle() }
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("MarDock Settings…", symbol: "gearshape") { [weak coordinator] in
            coordinator?.showSettings()
        })
        menu.addItem(ClosureMenuItem("Quit MarDock", symbol: "power") {
            NSApp.terminate(nil)
        })
        return menu
    }
}
