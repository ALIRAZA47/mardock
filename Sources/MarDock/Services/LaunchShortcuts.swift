import AppKit
import Carbon.HIToolbox
import MarDockCore

/// ⌃⌥1 to ⌃⌥9 (or the modifiers the user picked) open the dock's first nine
/// apps. These are Carbon hot keys: macOS hands MarDock only these exact key
/// combinations, so no Accessibility or Input Monitoring permission is needed
/// and no other keystroke is ever seen.
@MainActor
final class LaunchShortcuts {
    /// Called with 0 for the first app, up to 8 for the ninth.
    var onPress: ((Int) -> Void)?
    private(set) var shortcut: LaunchShortcut = .off
    /// How many of the nine combinations macOS accepted (another app may
    /// already own some).
    private(set) var registeredCount = 0
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    func update(_ shortcut: LaunchShortcut) {
        guard shortcut != self.shortcut else { return }
        unregister()
        self.shortcut = shortcut
        guard shortcut != .off else { return }
        installHandler()
        for (index, keyCode) in digitKeyCodes.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: launchShortcutSignature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(UInt32(keyCode), Self.modifiers(for: shortcut), id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeys.append(ref)
            }
        }
        registeredCount = hotKeys.count
    }

    private func unregister() {
        for ref in hotKeys {
            UnregisterEventHotKey(ref)
        }
        hotKeys.removeAll()
        registeredCount = 0
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), handleLaunchShortcut, 1, &spec, context, &handler)
    }

    fileprivate func pressed(_ index: Int) {
        onPress?(index)
    }

    static func modifiers(for shortcut: LaunchShortcut) -> UInt32 {
        switch shortcut {
        case .off: return 0
        case .controlOption: return UInt32(controlKey | optionKey)
        case .option: return UInt32(optionKey)
        case .commandOption: return UInt32(cmdKey | optionKey)
        }
    }
}

/// Receives MarDock's hot keys. Carbon calls it on the main thread, from
/// the app's event loop.
private func handleLaunchShortcut(_ call: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard status == noErr, id.signature == launchShortcutSignature, (1...9).contains(id.id) else {
        return OSStatus(eventNotHandledErr)
    }
    let index = Int(id.id) - 1
    MainActor.assumeIsolated {
        Unmanaged<LaunchShortcuts>.fromOpaque(context).takeUnretainedValue().pressed(index)
    }
    return noErr
}

/// 'MDck': marks MarDock's hot keys.
private let launchShortcutSignature: OSType = 0x4D44_636B

/// The 1–9 keys on the main keyboard (layout-independent key codes).
private let digitKeyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
