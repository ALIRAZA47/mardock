import AppKit
import ApplicationServices
import MarDockCore

/// The Accessibility work behind MarDock's opt-in extras: reading the
/// badges the macOS Dock shows, listing minimized windows and bringing one
/// back. None of it does anything unless the user turned one of those on
/// and allowed MarDock in System Settings ▸ Privacy & Security ▸
/// Accessibility; the helper reads nothing else of other apps.
enum WindowAccess {
    /// Accessibility calls can wait on a busy app, so they run here, off the
    /// queue the helper's other requests use.
    static let queue = DispatchQueue(label: "MarDockAgent.accessibility", qos: .userInitiated)

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own request (it appears once; after that the user
    /// decides in System Settings) and says whether it's allowed now.
    static func requestTrust() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// The badges on the macOS Dock's icons (it keeps them even while it is
    /// hidden), by app.
    static func badges(dockPID: pid_t) -> [DockBadge] {
        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.5)
        var badges: [DockBadge] = []
        for list in elements(dock, kAXChildrenAttribute) where string(list, kAXRoleAttribute) == kAXListRole {
            for item in elements(list, kAXChildrenAttribute) {
                guard let label = string(item, "AXStatusLabel"), !label.isEmpty,
                      let url = url(item, kAXURLAttribute),
                      let identifier = Bundle(url: url)?.bundleIdentifier
                else { continue }
                let badge = DockBadge(bundleIdentifier: identifier, label: label)
                guard badge.isValid else { continue }
                badges.append(badge)
                if badges.count == DockBadge.maxCount { return badges }
            }
        }
        return badges
    }

    /// Minimized windows of these apps: titles only.
    static func minimizedWindows(of apps: [(pid: pid_t, bundleIdentifier: String)]) -> [WindowInfo] {
        var result: [WindowInfo] = []
        for app in apps {
            let element = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(element, 0.25)
            for (index, window) in elements(element, kAXWindowsAttribute).prefix(WindowInfo.maxIndex + 1).enumerated()
            where bool(window, kAXMinimizedAttribute) == true {
                let info = WindowInfo(pid: app.pid, bundleIdentifier: app.bundleIdentifier, title: string(window, kAXTitleAttribute) ?? "", index: index)
                guard info.isValid else { continue }
                result.append(info)
                if result.count == WindowInfo.maxCount { return result }
            }
        }
        return result
    }

    /// Unminimizes and raises the window, and brings its app forward.
    /// The caller has already checked that `target.pid` is that app.
    static func show(_ target: WindowInfo) -> AgentReply {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let windows = elements(app, kAXWindowsAttribute)
        func title(_ window: AXUIElement) -> String {
            WindowInfo(pid: target.pid, bundleIdentifier: target.bundleIdentifier, title: string(window, kAXTitleAttribute) ?? "", index: 0).title
        }
        // The window where it was, if it's still there; otherwise the first
        // with the same title.
        let sameSpot = windows.indices.contains(target.index) && title(windows[target.index]) == target.title ? windows[target.index] : nil
        guard let window = sameSpot ?? windows.first(where: { title($0) == target.title }) else { return .failure(.notFound) }
        if bool(window, kAXMinimizedAttribute) == true {
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        return .done
    }

    // MARK: Reading attributes

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        (value(element, attribute) as? [AXUIElement]) ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (value(element, attribute) as? NSNumber)?.boolValue
    }

    private static func url(_ element: AXUIElement, _ attribute: String) -> URL? {
        value(element, attribute) as? URL
    }
}

/// Whether the Trash has anything in it, from the number of entries in
/// ~/.Trash: a directory attribute, so nothing in the Trash is opened or
/// listed.
enum TrashStatus {
    static func isFull() -> Bool? {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true).path
        guard let count = entryCount(of: trash) else { return nil }
        // Finder's own bookkeeping files don't count.
        let bookkeeping = [".DS_Store", ".localized"].filter { exists(trash + "/" + $0) }.count
        return count - bookkeeping > 0
    }

    private static func entryCount(of path: String) -> Int? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.dirattr = attrgroup_t(ATTR_DIR_ENTRYCOUNT)
        // The reply: its length, then the count.
        var reply: (length: UInt32, count: UInt32) = (0, 0)
        let status = withUnsafeMutableBytes(of: &reply) { buffer in
            getattrlist(path, &request, buffer.baseAddress, buffer.count, 0)
        }
        return status == 0 ? Int(reply.count) : nil
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
