import AppKit
import ApplicationServices
import MarDockCore

/// An app's own New and Open commands, for the shortcuts panel. It reads one
/// menu and presses one item in it, and `AppCommandFilter` decides what's
/// visible both times, so a request can't reach anything else: no other
/// menu, no recent-file names, nothing destructive. Like the rest of the
/// helper's Accessibility work, it does nothing until the user allows it.
enum MenuAccess {
    private struct Item {
        let element: AXUIElement
        let command: AppCommand
    }

    static func commands(pid: pid_t) -> [AppCommand] {
        items(pid: pid).map(\.command)
    }

    /// Brings the app forward and presses the item, if it's still offered.
    /// The caller has already checked that `pid` is that app.
    static func run(_ command: AppCommand, pid: pid_t) -> AgentReply {
        guard let item = items(pid: pid).first(where: { $0.command.title == command.title && $0.command.submenu == command.submenu }) else {
            return .failure(.notFound)
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        return AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success ? .done : .failure(.failed)
    }

    private static func items(pid: pid_t) -> [Item] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let bar = WindowAccess.element(app, kAXMenuBarAttribute) else { return [] }
        // Each element has its own timeout, and a busy app shouldn't hold up the queue.
        AXUIElementSetMessagingTimeout(bar, 0.4)
        let menus = WindowAccess.elements(bar, kAXChildrenAttribute)
        guard menus.indices.contains(AppCommandFilter.menuIndex) else { return [] }
        let title = menus[AppCommandFilter.menuIndex]
        AXUIElementSetMessagingTimeout(title, 0.4)
        guard let menu = WindowAccess.elements(title, kAXChildrenAttribute).first else { return [] }
        AXUIElementSetMessagingTimeout(menu, 0.4)

        var found: [Item] = []
        for element in WindowAccess.elements(menu, kAXChildrenAttribute) {
            let title = WindowAccess.string(element, kAXTitleAttribute) ?? ""
            if let submenu = WindowAccess.elements(element, kAXChildrenAttribute).first {
                // New Window can be a list of choices, as in Terminal. Other
                // submenus are never opened: Open Recent lists file names.
                guard AppCommandFilter.listsNewItems(title) else { continue }
                for child in WindowAccess.elements(submenu, kAXChildrenAttribute).prefix(32) {
                    add(child, submenu: title, to: &found)
                }
            } else {
                add(element, submenu: "", to: &found)
            }
            if found.count >= AppCommandFilter.maxCount { break }
        }
        return Array(found.prefix(AppCommandFilter.maxCount))
    }

    private static func add(_ element: AXUIElement, submenu: String, to found: inout [Item]) {
        let title = WindowAccess.string(element, kAXTitleAttribute) ?? ""
        let key = WindowAccess.string(element, "AXMenuItemCmdChar")
        let modifiers = (WindowAccess.value(element, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue
        guard WindowAccess.bool(element, kAXEnabledAttribute) != false,
              AppCommandFilter.isOffered(title: title, key: key, modifiers: modifiers)
        else { return }
        let command = AppCommand(title: title, keys: AppCommandFilter.keys(key: key, modifiers: modifiers), submenu: submenu)
        guard command.isValid, !found.contains(where: { $0.command == command }) else { return }
        found.append(Item(element: element, command: command))
    }
}
