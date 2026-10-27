import AppKit
import Foundation
import MarDockCore

/// Reads and writes the allowlisted subset of the macOS Dock's preferences.
enum DockPreferences {
    private static let domain = SystemDockSchema.domain as CFString

    static func read() -> [String: SystemDockValue] {
        CFPreferencesAppSynchronize(domain)
        var result: [String: SystemDockValue] = [:]
        for (key, kind) in SystemDockSchema.keys {
            guard let raw = CFPreferencesCopyAppValue(key as CFString, domain),
                  let value = convert(raw, kind: kind),
                  SystemDockSchema.isValid(key: key, value: value)
            else { continue }
            result[key] = value
        }
        return result
    }

    /// Writes a validated batch. Returns false (and writes nothing) if any
    /// change is outside the schema.
    static func write(_ changes: [SystemDockChange]) -> Bool {
        guard SystemDockSchema.isValid(changes) else { return false }
        for change in changes {
            let value = change.value.flatMap { propertyListValue(for: change.key, $0) }
            CFPreferencesSetAppValue(change.key as CFString, value, domain)
        }
        return CFPreferencesAppSynchronize(domain)
    }

    /// Where macOS keeps its Dock. Any app can claim the Dock's bundle
    /// identifier, so the helper only trusts a process running from here.
    static let dockBundlePath = "/System/Library/CoreServices/Dock.app"

    /// The macOS Dock, if it is running (normally exactly one process).
    static func runningDocks() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: SystemDockSchema.domain).filter {
            !$0.isTerminated && $0.bundleURL?.path == dockBundlePath
        }
    }

    /// The Dock only picks up most preferences when it starts, and launchd
    /// relaunches it immediately — exactly what `killall Dock` does.
    static func restartDock() {
        for dock in runningDocks() where dock.processIdentifier > 1 {
            kill(dock.processIdentifier, SIGTERM)
        }
    }

    /// Apps pinned in the macOS Dock, validated and filtered to ones that exist.
    static func pinnedApps() -> [ImportedDockApp] {
        CFPreferencesAppSynchronize(domain)
        let raw = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain)
        return PersistentAppsParser.parse(raw).filter { app in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private static func convert(_ raw: CFPropertyList, kind: SystemDockSchema.Kind) -> SystemDockValue? {
        switch kind {
        case .bool:
            guard let number = raw as? NSNumber else { return nil }
            return .bool(number.boolValue)
        case .integer, .real:
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return .number(number.doubleValue)
        case .choice:
            guard let string = raw as? String else { return nil }
            return .string(string)
        }
    }

    private static func propertyListValue(for key: String, _ value: SystemDockValue) -> CFPropertyList? {
        switch value {
        case let .bool(flag):
            return flag ? kCFBooleanTrue : kCFBooleanFalse
        case let .number(number):
            if case .integer = SystemDockSchema.keys[key] {
                return NSNumber(value: Int(number.rounded()))
            }
            return NSNumber(value: number)
        case let .string(string):
            return string as CFString
        }
    }
}

/// Quits, hides and shows apps on the dock's behalf — only ordinary,
/// user-facing apps.
enum AppTerminator {
    /// Parts of macOS that must never be quit from a dock menu.
    static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.windowmanager",
        "com.apple.wallpaper.agent",
        "com.apple.coreservices.uiagent",
    ]

    static func quit(
        pid: pid_t,
        bundleIdentifier: String,
        force: Bool,
        clientPID: pid_t,
        ownBundleIdentifiers: [String]
    ) -> AgentReply {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return .failure(.notFound)
        }
        // The pid must still belong to the app the dock thinks it is (pids
        // are reused), it must be a regular app, and never part of macOS or us.
        guard let actual = app.bundleIdentifier,
              actual.caseInsensitiveCompare(bundleIdentifier) == .orderedSame,
              app.activationPolicy == .regular,
              pid != clientPID, pid != getpid()
        else { return .failure(.notAllowed) }
        let lowered = actual.lowercased()
        guard !protectedBundleIdentifiers.contains(lowered), !ownBundleIdentifiers.contains(lowered) else {
            return .failure(.notAllowed)
        }
        let sent = force ? app.forceTerminate() : app.terminate()
        return sent ? .done : .failure(.failed)
    }

    /// Hiding is harmless, so unlike quitting it is allowed for Finder too.
    static func setHidden(
        pid: pid_t,
        bundleIdentifier: String,
        hidden: Bool,
        clientPID: pid_t,
        ownBundleIdentifiers: [String]
    ) -> AgentReply {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return .failure(.notFound)
        }
        guard let actual = app.bundleIdentifier,
              actual.caseInsensitiveCompare(bundleIdentifier) == .orderedSame,
              app.activationPolicy == .regular,
              pid != clientPID, pid != getpid(),
              !ownBundleIdentifiers.contains(actual.lowercased())
        else { return .failure(.notAllowed) }
        if app.isHidden != hidden {
            // The returned Bool is unreliable on recent macOS (it can be false
            // even when the app does hide), so callers check the outcome.
            _ = hidden ? app.hide() : app.unhide()
        }
        return .done
    }
}
