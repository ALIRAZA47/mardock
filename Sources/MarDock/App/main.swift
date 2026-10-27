import AppKit

/// MarDock runs as an agent app: no Dock tile or menu bar menus of its own,
/// just the dock window and a menu bar item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Don't let macOS kill us silently: on quit we may need to restore the
        // macOS Dock first.
        ProcessInfo.processInfo.disableAutomaticTermination("MarDock is the dock")
        ProcessInfo.processInfo.disableSuddenTermination()

        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        coordinator.prepareForTermination {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Opening MarDock again (from Finder or Spotlight) shows its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showSettings()
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    #if MARDOCK_SELFTEST
    if SelfTest.handle(arguments: CommandLine.arguments, application: application) {
        application.run()
        exit(0)
    }
    #endif
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        application.run()
    }
}
