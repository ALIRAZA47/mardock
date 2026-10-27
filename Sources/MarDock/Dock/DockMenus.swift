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
        let header = NSMenuItem(title: title(for: entry, controller: controller), action: nil, keyEquivalent: "")
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
        case .spacer:
            menu.addItem(ClosureMenuItem("Remove Spacer", symbol: "minus.circle") { [weak controller] in
                controller?.unpin(entry)
            })
            return menu
        case .divider:
            menu.addItem(ClosureMenuItem("Rename Divider…", symbol: "pencil") { [weak controller] in
                controller?.renameDivider(entry)
            })
            menu.addItem(ClosureMenuItem("Remove Divider", symbol: "minus.circle") { [weak controller] in
                controller?.unpin(entry)
            })
            return menu
        case let .folder(stack):
            menu.addItem(ClosureMenuItem("Open", symbol: "square.stack.3d.up") { [weak controller] in
                controller?.activate(entry, modifiers: [])
            })
            menu.addItem(ClosureMenuItem("Open in Finder", symbol: "folder") { [weak controller] in
                controller?.openFolderInFinder(entry)
            })
            menu.addItem(.separator())
            let display = NSMenu()
            for (choice, title) in [(FolderStack.Display.stack, "Stack"), (.folder, "Folder")] {
                display.addItem(ClosureMenuItem(title, state: stack.display == choice ? .on : .off) { [weak controller] in
                    controller?.updateFolder(entry, display: choice)
                })
            }
            let displayItem = NSMenuItem(title: "Display as", action: nil, keyEquivalent: "")
            displayItem.submenu = display
            menu.addItem(displayItem)
            let sorting = NSMenu()
            for (choice, title) in [(FolderStack.Sorting.dateAdded, "Date Added"), (.dateModified, "Date Modified"), (.name, "Name")] {
                sorting.addItem(ClosureMenuItem(title, state: stack.sorting == choice ? .on : .off) { [weak controller] in
                    controller?.updateFolder(entry, sorting: choice)
                })
            }
            let sortItem = NSMenuItem(title: "Sort by", action: nil, keyEquivalent: "")
            sortItem.submenu = sorting
            menu.addItem(sortItem)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Remove from Dock", symbol: "minus.circle") { [weak controller] in
                controller?.unpin(entry)
            })
            return menu
        case .window:
            menu.addItem(ClosureMenuItem("Show Window", symbol: "macwindow") { [weak controller] in
                controller?.activate(entry, modifiers: [])
            })
            return menu
        case .share:
            let hint = NSMenuItem(title: "Drop files here to share them with AirDrop, Mail or Messages.", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Remove from Dock", symbol: "minus.circle") { [weak controller] in
                controller?.unpin(entry)
            })
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
                menu.addItem(ClosureMenuItem("Unhide", symbol: "eye") { [weak controller] in
                    controller?.setHidden(app, false)
                })
            } else {
                menu.addItem(ClosureMenuItem("Hide", symbol: "eye.slash") { [weak controller] in
                    controller?.setHidden(app, true)
                })
            }
        } else {
            menu.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { [weak controller] in
                controller?.activate(entry, modifiers: [])
            })
        }
        menu.addItem(ClosureMenuItem("Show in Finder", symbol: "folder") { [weak controller] in
            controller?.activate(entry, modifiers: .command)
        })

        menu.addItem(.separator())
        switch entry.kind {
        case .pinned:
            menu.addItem(ClosureMenuItem("Remove from Dock", symbol: "minus.circle") { [weak controller] in
                controller?.unpin(entry)
            })
        case .recent:
            menu.addItem(ClosureMenuItem("Keep in Dock", symbol: "pin") { [weak controller] in
                controller?.keepInDock(entry)
            })
            menu.addItem(ClosureMenuItem("Remove from Recents", symbol: "minus.circle") { [weak controller] in
                controller?.unpin(entry)
            })
        case .running where controller.pinnable(entry) != nil:
            menu.addItem(ClosureMenuItem("Keep in Dock", symbol: "pin") { [weak controller] in
                controller?.keepInDock(entry)
            })
        default:
            break
        }
        menu.addItem(ClosureMenuItem("Change Icon…", symbol: "photo") { [weak controller] in
            controller?.chooseIcon(for: entry)
        })
        if controller.hasCustomIcon(entry) {
            menu.addItem(ClosureMenuItem("Use Original Icon", symbol: "arrow.uturn.backward") { [weak controller] in
                controller?.resetIcon(for: entry)
            })
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

    private static func title(for entry: DockEntry, controller: DockController) -> String {
        switch entry.kind {
        case .spacer: return "Spacer"
        case let .divider(title): return title.isEmpty ? "Divider" : title
        default: return controller.name(for: entry.id)
        }
    }

    /// The profiles, the one in use ticked, and New Profile….
    static func profileMenu(profiles: ProfileStore, controller: DockController?) -> NSMenu {
        let menu = NSMenu()
        for profile in profiles.profiles {
            menu.addItem(ClosureMenuItem(profile.name, state: profile.id == profiles.activeID ? .on : .off) { [weak profiles] in
                profiles?.activate(profile.id)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("New Profile…", symbol: "plus") { [weak controller] in
            controller?.newProfile()
        })
        return menu
    }

    /// The menu for the dock itself. `u` is where it was opened, so new
    /// spacers and dividers land there.
    static func dockMenu(controller: DockController, settings: SettingsStore, coordinator: AppCoordinator?, at u: Double?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let s = settings.settings

        let themes = NSMenu()
        let current = coordinator?.themes.recipe(for: s) ?? .builtIn(s.theme)
        for theme in ThemeID.allCases {
            themes.addItem(ClosureMenuItem(theme.displayName, state: current.id == ThemeRecipe.builtIn(theme).id ? .on : .off) { [weak settings] in
                settings?.update {
                    $0.theme = theme
                    $0.customTheme = nil
                }
            })
        }
        if let custom = coordinator?.themes.custom, !custom.isEmpty {
            themes.addItem(.separator())
            for recipe in custom {
                themes.addItem(ClosureMenuItem(recipe.name, state: current.id == recipe.id ? .on : .off) { [weak settings] in
                    settings?.update { $0.customTheme = recipe.id }
                })
            }
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

        if let profiles = coordinator?.profiles {
            let profileItem = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
            profileItem.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
            profileItem.submenu = profileMenu(profiles: profiles, controller: controller)
            menu.addItem(profileItem)
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Add Spacer", symbol: "rectangle.dashed") { [weak controller] in
            controller?.addItem(.newSpacer(), atU: u)
        })
        menu.addItem(ClosureMenuItem("Add Divider…", symbol: "rectangle.split.2x1") { [weak controller] in
            controller?.addItem(.newDivider(), atU: u)
        })
        menu.addItem(ClosureMenuItem("Add Folder…", symbol: "folder.badge.plus") { [weak controller] in
            controller?.addFolder(atU: u)
        })
        if !controller.hasShareTile {
            menu.addItem(ClosureMenuItem("Add Share Tile", symbol: "square.and.arrow.up") { [weak controller] in
                controller?.addItem(.share, atU: u)
            })
        }

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
