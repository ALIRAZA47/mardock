import AppKit
import CoreServices

/// Empties the Trash the way the macOS Dock does: by asking Finder to. The
/// sandbox lets MarDock send Finder exactly one kind of command, the ones in
/// Finder's `com.apple.finder.trash` group (see MarDock.entitlements), and
/// macOS asks you once whether MarDock may.
enum TrashEmptier {
    enum Failure: Error {
        /// Automation for Finder was turned down (or later turned off).
        case notAllowed
        case failed(OSStatus)
    }

    private static let finder = "com.apple.finder"
    private static let eventClass = fourCharCode("fndr")
    private static let eventID = fourCharCode("empt")

    /// Asks Finder to empty the Trash. Finder does the work, shows its own
    /// progress and plays its sound; this returns once Finder has the request.
    static func empty() async -> Result<Void, Failure> {
        // Asking for permission waits for your answer, so it stays off the
        // main thread.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: send())
            }
        }
    }

    private static func send() -> Result<Void, Failure> {
        let target = NSAppleEventDescriptor(bundleIdentifier: finder)
        let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc, eventClass, eventID, true)
        switch permission {
        case noErr: break
        case OSStatus(errAEEventNotPermitted), OSStatus(errAEEventWouldRequireUserConsent): return .failure(.notAllowed)
        default: return .failure(.failed(permission))
        }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: eventClass,
            eventID: eventID,
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        do {
            // No reply: emptying a big Trash takes a while, and Finder reports
            // its own problems (items in use, locked items).
            _ = try event.sendEvent(options: [.noReply], timeout: 10)
            return .success(())
        } catch {
            let code = OSStatus((error as NSError).code)
            return .failure(code == OSStatus(errAEEventNotPermitted) ? .notAllowed : .failed(code))
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func fourCharCode(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
