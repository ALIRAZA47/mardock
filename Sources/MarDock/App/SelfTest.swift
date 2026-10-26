#if MARDOCK_SELFTEST
// Compiled only into test builds (`-D MARDOCK_SELFTEST`), never into release.
//
// `--self-test` runs end-to-end checks of the security design against the real
// system: the sandbox is on and blocks the network, the helper accepts us and
// refuses anything outside its allowlist, and app launching/quitting works.
// `--demo` shows a dock with a given theme and a simulated pointer, so CI can
// take screenshots.

import AppKit
import MarDockCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum SelfTest {
    static func handle(arguments: [String], application: NSApplication) -> Bool {
        if arguments.contains("--self-test") {
            application.setActivationPolicy(.accessory)
            Task { @MainActor in
                let passed = await SelfTest.run()
                print("SELFTEST RESULT \(passed ? "PASS" : "FAIL")")
                fflush(stdout)
                exit(passed ? 0 : 1)
            }
            return true
        }
        if arguments.contains("--demo") {
            application.setActivationPolicy(.accessory)
            DemoMode.start(arguments: arguments)
            return true
        }
        return false
    }

    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        print("SELFTEST \(ok ? "PASS" : "FAIL") \(name) \(detail())")
        fflush(stdout)
    }

    static func run() async -> Bool {
        let agent = AgentClient()

        let workspace = NSWorkspace.shared
        info("accessibility", "reduceTransparency=\(workspace.accessibilityDisplayShouldReduceTransparency) increaseContrast=\(workspace.accessibilityDisplayShouldIncreaseContrast) reduceMotion=\(workspace.accessibilityDisplayShouldReduceMotion)")

        // 1. Sandbox and entitlements.
        check("sandbox-active", ProcessSecurity.isSandboxed)
        check("no-network-entitlement", !ProcessSecurity.hasEntitlement("com.apple.security.network.client"))
        let signature = CodeSignature.inspectSelf()
        check("signature-valid", signature.isValid, signature.status)
        check("hardened-runtime", signature.hasHardenedRuntime)

        // 2. The sandbox really blocks things.
        let realHome = String(cString: getpwuid(getuid()).pointee.pw_dir)
        let dockPlist = realHome + "/Library/Preferences/com.apple.dock.plist"
        check("sandbox-blocks-other-prefs", FileManager.default.contents(atPath: dockPlist) == nil, dockPlist)
        let networkErrno = attemptConnection()
        check("sandbox-blocks-network", networkErrno == EPERM || networkErrno == EACCES, "errno=\(networkErrno)")

        // 3. Things the dock needs still work inside the sandbox.
        if let calculator = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator") {
            let icon = IconProvider.render(NSWorkspace.shared.icon(forFile: calculator.path), pixels: 64)
            let generic = IconProvider.render(NSWorkspace.shared.icon(for: .applicationBundle), pixels: 64)
            check("icons-readable", icon != nil && pixelData(icon) != pixelData(generic))
        } else {
            check("icons-readable", false, "Calculator not found")
        }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]])?.count ?? 0
        check("window-list", windows > 0, "\(windows) windows")
        check("default-pins", !PinStore.defaultPins().isEmpty, "\(PinStore.defaultPins().count) apps")

        // Keyboard launching: hot keys register without any permission.
        let shortcuts = LaunchShortcuts()
        shortcuts.update(.controlOption)
        check("launch-shortcuts", shortcuts.registeredCount == 9, "\(shortcuts.registeredCount) of 9")
        shortcuts.update(.off)

        // Custom icons are stored in, and read back from, the container.
        let iconID = DockIdentity.app("io.github.aliraza47.mardock.selftest")
        let iconStore = CustomIconStore()
        do {
            try iconStore.setIcon(IconProvider.shareIcon, for: iconID)
            check("custom-icon", CustomIconStore().icon(for: iconID) != nil)
        } catch {
            check("custom-icon", false, error.localizedDescription)
        }
        iconStore.removeIcon(for: iconID)
        check("custom-icon-removed", !CustomIconStore().hasIcon(for: iconID))

        // Folder stacks: bookmark a folder, open it again through the
        // bookmark, list its newest files and draw the stack.
        checkFolderStack()

        // Profiles keep their own items, swap them in and survive a relaunch.
        checkProfiles()

        // 4. The helper.
        do {
            let info = try await agent.hello()
            check("helper-hello", true, "v\(info.protocolVersion)")
            check("helper-unsandboxed", !info.isSandboxed)
            check("helper-pins-client", !info.clientRequirement.isEmpty, info.clientRequirement)
        } catch {
            check("helper-hello", false, error.localizedDescription)
        }
        do {
            let values = try await agent.readSystemDock()
            check("helper-read-dock", true, "\(values.count) keys")
        } catch {
            check("helper-read-dock", false, error.localizedDescription)
        }
        do {
            let apps = try await agent.importSystemDockApps()
            check("helper-import-apps", true, "\(apps.count) apps")
        } catch {
            check("helper-import-apps", false, error.localizedDescription)
        }
        do {
            let report = try await agent.verifyIntegrity()
            check("helper-integrity", report.appSignatureValid && report.helperSignatureValid, report.detail)
        } catch {
            check("helper-integrity", false, error.localizedDescription)
        }

        // 5. The helper refuses what it must refuse.
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            await expectRefusal("helper-refuses-quitting-dock", .notAllowed) {
                try await agent.quit(pid: dock.processIdentifier, bundleIdentifier: "com.apple.dock", force: true)
            }
        }
        await expectRefusal("helper-refuses-pid-mismatch", .notAllowed) {
            try await agent.quit(pid: getpid(), bundleIdentifier: "com.apple.Safari", force: true)
        }
        await expectRefusal("helper-refuses-unknown-key", .invalidRequest) {
            _ = try await agent.send(.applySystemDock(changes: [SystemDockChange(key: "persistent-apps", value: .string("x"))], restartDock: true))
        }
        await expectRefusal("helper-refuses-out-of-range", .invalidRequest) {
            _ = try await agent.send(.applySystemDock(changes: [SystemDockChange(key: "tilesize", value: .number(100_000))], restartDock: false))
        }
        let garbage = await sendRaw(Data("{\"runShell\":{\"command\":\"id\"}}".utf8))
        check("helper-refuses-garbage", garbage == .failure(.invalidRequest), "\(String(describing: garbage))")

        // 6. Hiding the macOS Dock and putting it back exactly as it was.
        await systemDockRoundTrip(agent: agent)
        do {
            try await agent.openTrash()
            check("open-trash", true)
        } catch {
            check("open-trash", false, error.localizedDescription)
        }

        // 7. Launch, hide and quit a real app.
        await launchHideQuit(agent: agent)

        // 8. The renderer survives a full frame in every theme.
        renderSmokeTest()

        return failures == 0
    }

    private static func checkFolderStack() {
        let fileManager = FileManager.default
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            check("folder-stack", false, "no Application Support folder")
            return
        }
        let folder = base.appendingPathComponent("SelfTestStack", isDirectory: true)
        defer { try? fileManager.removeItem(at: folder) }
        try? fileManager.removeItem(at: folder)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, name) in ["Old.txt", "Middle.txt", "Newest.txt"].enumerated() {
                let file = folder.appendingPathComponent(name)
                try Data(name.utf8).write(to: file)
                try fileManager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 60)], ofItemAtPath: file.path)
            }
        } catch {
            check("folder-stack", false, error.localizedDescription)
            return
        }
        guard var stack = FolderStacks.makeStack(for: folder) else {
            check("folder-stack", false, "couldn't bookmark the folder")
            return
        }
        stack.sorting = .dateModified
        let stacks = FolderStacks()
        let files = stacks.files(in: stack)
        let names = files.map(\.url.lastPathComponent)
        let drawn = IconProvider.render(stacks.icon(for: stack), pixels: 64) != nil
        check("folder-stack", names.first == "Newest.txt" && names.count == 3 && drawn, names.joined(separator: ", "))
    }

    private static func checkProfiles() {
        let suite = "io.github.aliraza47.mardock.selftest.profiles"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check("profiles", false, "no defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = PinStore(defaults: defaults)
        let profiles = ProfileStore(pins: pins, defaults: defaults)
        let first = profiles.activeID
        let firstItems = pins.items
        let second = profiles.create(named: "Self-test")
        pins.insert(.newSpacer())
        let secondItems = pins.items
        profiles.activate(first)
        let restored = pins.items == firstItems
        if let second { profiles.activate(second) }
        let swapped = pins.items == secondItems
        let reloaded = ProfileStore(pins: PinStore(defaults: defaults), defaults: defaults)
        check(
            "profiles",
            second != nil && restored && swapped && reloaded.profiles.count == 2 && reloaded.activeID == second,
            "restored \(restored), swapped \(swapped), \(reloaded.profiles.count) after a relaunch"
        )
    }

    private static func expectRefusal(_ name: String, _ expected: AgentFailure, _ body: () async throws -> Void) async {
        do {
            try await body()
            check(name, false, "was allowed")
        } catch let error as AgentClientError {
            check(name, error == .refused(expected), "\(error)")
        } catch {
            check(name, false, "\(error)")
        }
    }

    private static func sendRaw(_ payload: Data) async -> AgentReply? {
        let connection = NSXPCConnection(serviceName: AppInfo.agentServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: MarDockAgentXPC.self)
        connection.resume()
        defer { connection.invalidate() }
        return await withCheckedContinuation { continuation in
            let once = OnceBox(continuation)
            guard let agent = connection.remoteObjectProxyWithErrorHandler({ _ in once.resume(nil) }) as? MarDockAgentXPC else {
                once.resume(nil)
                return
            }
            agent.handle(payload) { data in
                once.resume(try? AgentWire.decode(AgentReply.self, from: data))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { once.resume(nil) }
        }
    }

    private static func attemptConnection() -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(443).bigEndian
        address.sin_addr.s_addr = inet_addr("192.0.2.1") // TEST-NET-1: never routed
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0 ? 0 : errno
    }

    private static func pixelData(_ image: CGImage?) -> Data? {
        guard let data = image?.dataProvider?.data else { return nil }
        return data as Data
    }

    private static func info(_ name: String, _ detail: String) {
        print("SELFTEST INFO \(name) \(detail)")
        fflush(stdout)
    }

    private static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    private static func systemDockRoundTrip(agent: AgentClient) async {
        let suite = "io.github.aliraza47.MarDock.selftest"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check("system-dock-hide", false, "no defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        let manager = SystemDockManager(agent: agent, defaults: defaults)
        await manager.refresh()
        let before = manager.values
        let hid = await manager.hide()
        check("system-dock-hide", hid && manager.looksHidden && manager.isHiddenByMarDock, "\(manager.values)")
        try? await Task.sleep(nanoseconds: 1_700_000_000) // let the Dock restart (and the helper's limiter) settle
        let restored = await manager.restore()
        await manager.refresh()
        let after = manager.values
        let same = after["autohide"] == before["autohide"] && after["autohide-delay"] == before["autohide-delay"]
        check("system-dock-restore", restored && same && !manager.isHiddenByMarDock, "before \(before) after \(after)")
        defaults.removePersistentDomain(forName: suite)
        try? await Task.sleep(nanoseconds: 1_700_000_000)
    }

    private static func probeHiding(_ app: NSRunningApplication, agent: AgentClient, label: String) async {
        let returned = app.hide()
        let direct = await waitUntil(2) { app.isHidden }
        _ = app.unhide()
        _ = await waitUntil(2) { !app.isHidden }
        var viaHelper = false
        if let identifier = app.bundleIdentifier,
           (try? await agent.setHidden(pid: app.processIdentifier, bundleIdentifier: identifier, hidden: true)) != nil {
            viaHelper = await waitUntil(2) { app.isHidden }
            _ = try? await agent.setHidden(pid: app.processIdentifier, bundleIdentifier: identifier, hidden: false)
            _ = await waitUntil(2) { !app.isHidden }
        }
        if app.isHidden {
            _ = app.unhide()
            _ = await waitUntil(2) { !app.isHidden }
        }
        info("hide-\(label)", "direct: returned \(returned), hid \(direct); helper: hid \(viaHelper)")
    }

    private static func launchHideQuit(agent: AgentClient) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator") else {
            check("launch", false, "Calculator not found")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let app: NSRunningApplication? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
                continuation.resume(returning: app)
            }
        }
        guard let app, let identifier = app.bundleIdentifier else {
            check("launch", false, "openApplication failed")
            return
        }
        check("launch", true, "pid \(app.processIdentifier)")
        _ = await waitUntil(5) { app.isFinishedLaunching }

        // How each way of hiding behaves here (informational).
        await probeHiding(app, agent: agent, label: "background")

        // Bringing a running app forward the way the dock does it.
        let activate = NSWorkspace.OpenConfiguration()
        activate.activates = true
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            NSWorkspace.shared.openApplication(at: url, configuration: activate) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
        let activated = await waitUntil(3) { app.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
        check("activate", activated)
        await probeHiding(app, agent: agent, label: "frontmost")

        // The code path the dock actually uses.
        let actions = AppActions(agent: agent, pins: PinStore())
        actions.setHidden(app, true)
        check("hide", await waitUntil(4) { app.isHidden })
        actions.setHidden(app, false)
        check("unhide", await waitUntil(4) { !app.isHidden })

        do {
            try await agent.quit(pid: app.processIdentifier, bundleIdentifier: identifier, force: false)
            check("quit-via-helper", await waitUntil(8) { app.isTerminated })
        } catch {
            check("quit-via-helper", false, error.localizedDescription)
            _ = app.forceTerminate()
        }
    }

    private static func renderSmokeTest() {
        for theme in ThemeID.allCases {
            var settings = DockSettings()
            settings.theme = theme
            let preview = DockPreviewView(settings: settings)
            preview.frame = NSRect(x: 0, y: 0, width: 720, height: 220)
            preview.update(settings: settings)
            check("render-\(theme.rawValue)", true)
        }
    }
}

private final class OnceBox<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// Shows a real dock with a chosen theme and a simulated pointer.
@MainActor
enum DemoMode {
    private static var coordinator: AppCoordinator?

    static func start(arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let coordinator = AppCoordinator()
        Self.coordinator = coordinator
        coordinator.settings.hasCompletedOnboarding = true
        coordinator.settings.update { s in
            s = DockSettings()
            s.theme = value("--theme").flatMap(ThemeID.init(rawValue:)) ?? .glass
            s.position = value("--position").flatMap(DockPosition.init(rawValue:)) ?? .bottom
            s.hideSystemDock = false
        }
        let touring = arguments.contains("--tour")
        var pins = PinStore.defaultPins()
        if touring, let calculator = AppCatalog.pinnedApp(bundleIdentifier: "com.apple.calculator") {
            // Third in the dock, so ⌃⌥3 reaches it.
            pins.insert(calculator, at: min(1, pins.count))
        }
        // Start clean, with a Work and a Personal profile.
        for id in coordinator.customIcons.iconIDs {
            coordinator.customIcons.removeIcon(for: id)
        }
        for theme in coordinator.themes.custom {
            coordinator.themes.delete(theme.id)
        }
        let personal = personalApps.compactMap { AppCatalog.pinnedApp(bundleIdentifier: $0) }
        coordinator.profiles.replace(with: DockProfiles(
            profiles: [
                DockProfile(name: "Work", items: pins.map(DockItem.app)),
                DockProfile(name: "Personal", items: personal.map(DockItem.app)),
            ],
            activeID: nil
        ))
        if arguments.contains("--backdrop") {
            showBackdrop()
        }
        coordinator.running.start()
        if touring {
            coordinator.recents.start()
        }
        coordinator.dock.start()
        if touring {
            DemoTour.start(coordinator)
            return
        }
        coordinator.dock.stopPointerTracking()

        switch value("--window") {
        case "settings":
            if let pane = value("--pane").flatMap(SettingsView.Pane.init(rawValue:)) {
                coordinator.showSettings(pane: pane)
            } else {
                coordinator.showSettings()
            }
            reportWindow(titled: "MarDock Settings")
        case "theme-editor":
            showThemeEditor(neonCandy, coordinator: coordinator, nearTop: false)
            reportWindow(titled: "Theme Editor")
        case "welcome":
            coordinator.showWelcome()
            reportWindow(titled: "Welcome to MarDock")
        default:
            let hover = value("--hover").flatMap(Double.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated {
                    if let hover { coordinator.dock.simulatePointer(fraction: hover) }
                    print("DEMO READY \(coordinator.dock.shelfScreenRect().debugDescription)")
                    fflush(stdout)
                }
            }
        }
    }

    /// The Personal profile's apps (those this Mac has).
    static let personalApps = [
        "com.apple.Safari", "com.apple.MobileSMS", "com.apple.FaceTime", "com.apple.Photos", "com.apple.Music",
        "com.apple.TV", "com.apple.podcasts", "com.apple.Maps", "com.apple.weather", "com.apple.Chess",
    ]

    /// A theme as someone might make in the theme editor.
    static var neonCandy: ThemeRecipe {
        var r = ThemeRecipe.builtIn(.midnight).duplicate(named: "Neon Candy")
        r.tint = [ThemeColor(hex: 0x2A0845), ThemeColor(hex: 0x4B1D7A), ThemeColor(hex: 0x0B3A5B)]
        r.tintOpacity = 0.58
        r.aurora = [ThemeColor(hex: 0xFF4FD8), ThemeColor(hex: 0x00E5FF), ThemeColor(hex: 0xFFD86F)]
        r.auroraOpacity = 0.42
        r.borderStart = ThemeColor(hex: 0xFF4FD8, alpha: 0.95)
        r.borderEnd = ThemeColor(hex: 0x00E5FF, alpha: 0.85)
        r.borderWidth = 1.4
        r.edgeGlow = ThemeColor(hex: 0xFF4FD8)
        r.accent = ThemeColor(hex: 0xFF4FD8)
        r.indicatorGlow = 1
        r.cornerFactor = 0.4
        r.swatch = [ThemeColor(hex: 0xFF4FD8), ThemeColor(hex: 0x00E5FF)]
        return r.sanitized()
    }

    /// The theme editor in a window of its own (in the app it's a sheet on
    /// Settings), near the top of the screen or in the middle.
    @discardableResult
    static func showThemeEditor(_ recipe: ThemeRecipe, coordinator: AppCoordinator, nearTop: Bool) -> NSWindow {
        let root = ThemeEditor(recipe: recipe)
            .environmentObject(coordinator.settings)
            .environmentObject(coordinator.themes)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Theme Editor"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        if nearTop, let screen = NSScreen.screens.first {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: screen.frame.midX - frame.width / 2, y: screen.frame.maxY - frame.height - 6))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Sample files for the tour's Downloads stack, newest first.
    static func makeTourDownloads() -> FolderStack? {
        let fileManager = FileManager.default
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Tour", isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
        try? fileManager.removeItem(at: folder)
        let names = [
            "Holiday photos.zip", "Boarding pass.pdf", "Screenshot.png", "Launch film.mov",
            "Demo song.m4a", "Notes from today.txt", "Budget.csv", "Website.html",
        ]
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, name) in names.enumerated() {
                let file = folder.appendingPathComponent(name)
                try Data(name.utf8).write(to: file)
                try fileManager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(-index) * 3600)], ofItemAtPath: file.path)
            }
        } catch {
            return nil
        }
        guard var stack = FolderStacks.makeStack(for: folder) else { return nil }
        stack.sorting = .dateModified
        return stack
    }

    private static var backdrop: NSWindow?

    /// Puts the pretend wallpaper back in front of other apps' windows.
    static func raiseBackdrop() {
        backdrop?.orderFrontRegardless()
    }

    /// A colourful "wallpaper" window behind the dock, so screenshots show
    /// what the glass does (CI desktops are plain black).
    private static func showBackdrop() {
        guard let screen = NSScreen.screens.first else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .normal
        window.backgroundColor = .black
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let host = LayerHostView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = host
        guard let root = host.layer else { return }
        let base = CAGradientLayer()
        base.frame = root.bounds
        let colors: [UInt32] = [0x1D2671, 0x5B2A86, 0xC33764, 0xF7971E]
        base.colors = colors.map { NSColor(hex: $0).cgColor }
        base.startPoint = CGPoint(x: 0, y: 1)
        base.endPoint = CGPoint(x: 1, y: 0)
        root.addSublayer(base)
        let blobs: [(CGFloat, CGFloat, CGFloat, UInt32)] = [(0.16, 0.1, 0.45, 0x30CFD0), (0.5, 0.05, 0.4, 0xFFD86F), (0.84, 0.16, 0.45, 0xFF6FD8)]
        for (x, y, scale, hex) in blobs {
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            blob.colors = [NSColor(hex: hex, alpha: 0.9).cgColor, NSColor(hex: hex, alpha: 0).cgColor]
            let size = root.bounds.width * scale
            blob.frame = CGRect(x: root.bounds.width * x - size / 2, y: root.bounds.height * y - size / 2, width: size, height: size)
            root.addSublayer(blob)
        }
        window.orderFrontRegardless()
        backdrop = window
    }

    private static func reportWindow(titled title: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard let window = NSApp.windows.first(where: { $0.title == title }),
                      let screen = window.screen ?? NSScreen.screens.first
                else {
                    print("DEMO WINDOW MISSING")
                    fflush(stdout)
                    return
                }
                let f = window.frame
                let rect = CGRect(x: f.minX, y: screen.frame.maxY - f.maxY, width: f.width, height: f.height)
                print("DEMO WINDOW \(rect.debugDescription)")
                fflush(stdout)
            }
        }
    }
}

/// `--demo --tour`: plays a scripted tour of the real dock for CI to record.
/// The tour moves the real pointer and hands each position to the dock along
/// the path real mouse movement takes (a pointer moved by software sends no
/// events); the click, the menus and the settings changes are the real ones.
/// Every step is due at a fixed time, so however slowly the runner draws, the
/// tour fits the recording, which runs for a fixed time.
@MainActor
final class DemoTour {
    /// How long to record after "TOUR READY": the tour, then a moment's hold.
    static let seconds = 71
    private static var current: DemoTour?
    private static let calculatorBundleIdentifier = "com.apple.calculator"

    private let coordinator: AppCoordinator
    private let caption = KeyCaption()
    private var point = NSPoint.zero
    /// When the tour began, and how many seconds into it the next step is due.
    private var began = 0.0
    private var due = 0.0
    private var activity: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    /// A Downloads folder with a few files, for the folder stack.
    private var downloads: FolderStack?
    private var dock: DockController { coordinator.dock }
    private var screen: NSRect { NSScreen.screens.first?.frame ?? .zero }
    private var elapsed: Double { ProcessInfo.processInfo.systemUptime - began }

    private init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    static func start(_ coordinator: AppCoordinator) {
        let tour = DemoTour(coordinator: coordinator)
        current = tour
        tour.prepare()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // The recorder starts on this line; give it a moment before the first move.
            print("TOUR READY \(seconds)")
            fflush(stdout)
            tour.began = ProcessInfo.processInfo.systemUptime
            await tour.pause(2)
            await tour.run()
            print(String(format: "TOUR DONE after %.1f s", tour.elapsed))
            fflush(stdout)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            exit(0)
        }
    }

    private func prepare() {
        // Nothing may throttle the tour's timers while it is recorded.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Recording a tour of the dock"
        )
        // When Calculator hides, the system brings another app forward. Hide
        // the others (the self-test leaves a Finder window open) so that it
        // has nothing to show, and should one come forward anyway, keep its
        // windows behind the pretend desktop.
        NSWorkspace.shared.hideOtherApplications()
        NSApp.activate()
        let demoed = Self.calculatorBundleIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier != demoed else { return }
            MainActor.assumeIsolated { DemoMode.raiseBackdrop() }
        }
        downloads = DemoMode.makeTourDownloads()
        move(to: NSPoint(x: screen.midX, y: screen.minY + screen.height * 0.55))
    }

    private func run() async {
        let calculator = DockIdentity.app(Self.calculatorBundleIdentifier)
        let notes = DockIdentity.app("com.apple.notes")
        guard let first = dock.restingCenter(of: DockIdentity.finder), let last = dock.restingCenter(of: DockIdentity.trash) else {
            print("TOUR FAIL the dock has no tiles")
            return
        }
        let middle = (first.x + last.x) / 2

        // Hover: icons swell under the pointer and their names float above.
        await glide(to: NSPoint(x: first.x + 30, y: first.y), over: 1.0)
        await glide(to: NSPoint(x: last.x - 20, y: first.y), over: 2.6)
        await glide(to: NSPoint(x: middle, y: first.y), over: 1.0)

        // Open an app: it bounces while it launches, then its light comes on.
        await glide(toTile: calculator, over: 0.9)
        dock.demoClick(calculator)
        await pause(2.4)

        // Its menu, then Hide: the window goes and the icon dims.
        showMenu(of: calculator, choosing: "Hide", after: 1.4)
        await pause(0.6)

        // Back from the keyboard: ⌃⌥ and its place in the dock.
        await glide(to: NSPoint(x: point.x, y: screen.midY), over: 0.7)
        if let slot = dock.shortcutSlot(of: calculator) {
            caption.show(LaunchShortcut.controlOption.symbols + "\(slot + 1)", over: screen)
            dock.openShortcutTarget(slot)
        }
        await pause(1.8)
        caption.hide()

        // Every theme.
        for theme in [ThemeID.aurora, .midnight, .sunset, .liquid, .mirror, .minimal, .glass] {
            coordinator.settings.update { $0.theme = theme }
            let row = dock.restingCenter(of: DockIdentity.finder)?.y ?? first.y
            await glide(to: NSPoint(x: middle - 110, y: row), over: 0.6)
            await glide(to: NSPoint(x: middle + 110, y: row), over: 0.6)
        }

        // A theme of one's own, from the theme editor: over its live
        // preview, down its controls, then Save.
        let recipe = DemoMode.neonCandy
        let editor = DemoMode.showThemeEditor(recipe, coordinator: coordinator, nearTop: true)
        let sheet = editor.frame
        await glide(to: NSPoint(x: sheet.midX + 90, y: sheet.maxY - 110), over: 0.9)
        await glide(to: NSPoint(x: sheet.midX + 160, y: sheet.midY + 20), over: 0.9)
        await glide(to: NSPoint(x: sheet.maxX - 46, y: sheet.minY + 27), over: 0.9)
        await pause(0.3)
        editor.close()
        coordinator.themes.save(recipe)
        coordinator.settings.update { $0.customTheme = recipe.id }
        let themed = dock.restingCenter(of: DockIdentity.finder)?.y ?? first.y
        await glide(to: NSPoint(x: middle - 140, y: themed), over: 0.9)
        await glide(to: NSPoint(x: middle + 140, y: themed), over: 0.9)

        // A spacer and the Share tile from the dock's own menu, and a named divider.
        if let after = dock.restingCenter(of: notes) {
            let gap = NSPoint(x: after.x + CGFloat(dock.engine.metrics.slot) / 2, y: after.y)
            await glide(to: gap, over: 0.8)
            showDockMenu(at: gap, choosing: "Add Spacer", after: 1.2)
            await pause(0.5)
            if let index = coordinator.pins.items.firstIndex(where: { $0.id == DockIdentity.app("com.apple.photos") }) {
                coordinator.pins.insert(.divider(id: DockIdentity.newTile(.divider), title: "Create"), at: index)
            }
            await pause(0.8)
        }
        if let end = dock.restingCenter(of: DockIdentity.trash) {
            let spot = NSPoint(x: end.x - CGFloat(dock.engine.metrics.slot) * 1.1, y: end.y)
            await glide(to: spot, over: 0.8)
            showDockMenu(at: spot, choosing: "Add Share Tile", after: 1.2)
            await pause(0.6)
        }
        if let divider = coordinator.pins.items.first(where: { if case .divider = $0 { return true } else { return false } }) {
            await glide(toTile: divider.id, over: 0.9)
            await pause(0.8)
        }
        await glide(toTile: DockIdentity.share, over: 1.1)
        await pause(0.7)

        // A custom icon for Notes.
        await glide(toTile: notes, over: 0.8)
        showMenu(of: notes, choosing: "(just look)", after: 1.0)
        try? coordinator.customIcons.setIcon(IconProvider.symbolTile("star.fill", top: NSColor(hex: 0xFFD86F), bottom: NSColor(hex: 0xFF6FD8)), for: notes)
        await pause(1.2)

        // A folder in the dock: a click fans its newest files out above it,
        // and another click puts them away.
        if let stack = downloads {
            coordinator.pins.insert(.folder(stack))
            await pause(0.6)
            await glide(toTile: stack.id, over: 0.9)
            dock.demoClick(stack.id)
            await pause(0.5)
            if let tile = dock.restingCenter(of: stack.id) {
                await glide(to: NSPoint(x: tile.x + 12, y: tile.y + 300), over: 1.4)
                await pause(0.6)
                await glide(to: tile, over: 0.7)
            } else {
                await pause(2.1)
            }
            dock.demoClick(stack.id)
            await pause(0.6)
        }

        // Profiles: the dock's menu, then Personal's apps, then back to Work.
        let work = coordinator.profiles.activeID
        if let personal = coordinator.profiles.profiles.first(where: { $0.name == "Personal" }),
           let left = dock.restingCenter(of: DockIdentity.finder) {
            let spot = NSPoint(x: left.x + CGFloat(dock.engine.metrics.slot) * 2.5, y: left.y)
            await glide(to: spot, over: 0.8)
            showDockMenu(at: spot, choosing: "(just look)", after: 1.2)
            showProfileMenu(at: spot, choosing: personal.name, after: 1.1)
            if coordinator.profiles.activeID != personal.id {
                coordinator.profiles.activate(personal.id)
            }
            await pause(0.4)
            let row = dock.restingCenter(of: DockIdentity.finder)?.y ?? first.y
            await glide(to: NSPoint(x: middle + 160, y: row), over: 1.4)
            showProfileMenu(at: NSPoint(x: middle + 160, y: row), choosing: "Work", after: 1.0)
            if coordinator.profiles.activeID != work {
                coordinator.profiles.activate(work)
            }
            await pause(0.6)
        }

        // Auto-hide: it slides away when the pointer leaves, and comes back at the edge.
        coordinator.settings.update { $0.autoHide = .always }
        await glide(to: NSPoint(x: point.x, y: screen.midY), over: 0.8)
        await pause(0.9)
        await glide(to: NSPoint(x: screen.midX, y: screen.minY + 0.5), over: 0.9)
        await pause(1.0)
        await glide(to: NSPoint(x: screen.midX, y: first.y), over: 0.5)
        coordinator.settings.update { $0.autoHide = .off }
        await pause(0.4)

        // On the left side of the screen.
        coordinator.settings.update { $0.position = .left }
        await pause(0.9)
        if let top = dock.restingCenter(of: DockIdentity.finder), let bottom = dock.restingCenter(of: DockIdentity.trash) {
            await glide(to: NSPoint(x: top.x, y: top.y - 20), over: 0.8)
            await glide(to: NSPoint(x: top.x, y: bottom.y + 20), over: 2.0)
        } else {
            await pause(2.8)
        }
        coordinator.settings.update { $0.position = .bottom }
        await pause(0.9)

        // Out of the dock while it runs, then Quit: it stays as a recent app.
        await glide(toTile: calculator, over: 0.8)
        showMenu(of: calculator, choosing: "Remove from Dock", after: 1.2)
        await pause(0.8)
        await glide(toTile: calculator, over: 0.8)
        showMenu(of: calculator, choosing: "Quit", after: 1.2)
        await pause(1.4)
        await glide(to: NSPoint(x: point.x, y: screen.midY), over: 0.8)
        await pause(0.8)
    }

    private func move(to p: NSPoint) {
        point = p
        dock.demoPointer(at: p)
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: screen.maxY - p.y))
    }

    /// Glides the pointer to `target` along an eased path that ends when the
    /// step is due. Running late, it hurries to catch up rather than jumping.
    private func glide(to target: NSPoint, over seconds: Double) async {
        let from = point
        let start = max(due, elapsed)
        due += seconds
        let span = max(due - start, 0.001)
        while true {
            let t = min(max((elapsed - start) / span, 0), 1)
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            move(to: NSPoint(x: from.x + (target.x - from.x) * e, y: from.y + (target.y - from.y) * e))
            if t >= 1 { return }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    private func glide(toTile id: String, over seconds: Double) async {
        if let target = dock.restingCenter(of: id) {
            await glide(to: target, over: seconds)
        } else {
            await pause(seconds)
        }
    }

    /// Opens a tile's menu for `seconds` (the call returns once it closes),
    /// then picks the item titled `title`.
    private func showMenu(of id: String, choosing title: String, after seconds: Double) {
        due += seconds
        dock.demoMenu(for: id, choosing: title, after: seconds)
    }

    /// Opens the dock's own menu at `screenPoint` for `seconds`, then picks
    /// the item titled `title`.
    private func showDockMenu(at screenPoint: NSPoint, choosing title: String, after seconds: Double) {
        due += seconds
        dock.demoDockMenu(at: screenPoint, choosing: title, after: seconds)
    }

    /// Opens the profile list (the dock menu's Profile submenu) at
    /// `screenPoint` for `seconds`, then picks the profile named `title`.
    private func showProfileMenu(at screenPoint: NSPoint, choosing title: String, after seconds: Double) {
        due += seconds
        dock.demoProfileMenu(at: screenPoint, choosing: title, after: seconds)
    }

    /// Waits until the end of a pause of `seconds`.
    private func pause(_ seconds: Double) async {
        due += seconds
        let wait = due - elapsed
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }
}

/// A keystroke caption for the recording, like a screencast's key overlay.
@MainActor
final class KeyCaption {
    private let window: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.maskImage = DockView.roundedMask(radius: 18)
        window.contentView = effect
        label.font = .systemFont(ofSize: 36, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        effect.addSubview(label)
    }

    func show(_ text: String, over screen: NSRect) {
        label.stringValue = text
        let textSize = label.intrinsicContentSize
        let size = NSSize(width: max(150, ceil(textSize.width) + 64), height: 76)
        window.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + screen.height * 0.6, width: size.width, height: size.height), display: true)
        label.frame = NSRect(x: 0, y: (size.height - textSize.height) / 2, width: size.width, height: textSize.height)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}

extension DockController {
    /// Places a pretend pointer over the dock (0 = first tile, 1 = last).
    func simulatePointer(fraction: Double) {
        let frame = engine.lastFrame
        let u = frame.shelfStart + (frame.shelfEnd - frame.shelfStart) * min(max(fraction, 0), 1)
        engine.setPointer(DockPointer(u: u, v: engine.metrics.edgeGap + engine.metrics.shelfThickness / 2))
        for _ in 0..<90 { dockView.apply(engine.tick(1.0 / 60)) }
    }

    /// Where the pointer has to be for tile `id` to end up under it: the
    /// tile's centre with the magnification taken out. The magnifier keeps
    /// whatever is under the pointer in place, so aiming at a tile's
    /// magnified position lands on one of its neighbours instead.
    func restingCenter(of id: String) -> NSPoint? {
        let frame = engine.lastFrame
        let m = engine.metrics
        guard let item = frame.item(id: id), let window = dockView.window else { return nil }
        let magnifier = Magnifier(focus: frame.focus, peakScale: 1 + (m.peakScale - 1) * frame.magnification, radius: m.radius)
        func unwarp(_ x: Double) -> Double {
            var lo = x - magnifier.maxGrowthPerSide - 1
            var hi = x + magnifier.maxGrowthPerSide + 1
            for _ in 0..<50 {
                let mid = (lo + hi) / 2
                if magnifier.warp(mid) < x { lo = mid } else { hi = mid }
            }
            return (lo + hi) / 2
        }
        let u = (unwarp(item.slotStart) + unwarp(item.slotEnd)) / 2
        let size = dockView.bounds.size
        let axis = DockAxis(position: dockView.configuration.position, width: Double(size.width), height: Double(size.height))
        let p = axis.toView(u: u, v: item.baseline + m.iconSize / 2)
        return window.convertPoint(toScreen: dockView.convert(NSPoint(x: p.x, y: p.y), to: nil))
    }

    /// The area around the shelf worth screenshotting, in screen coordinates
    /// with a top-left origin (what `screencapture -R` expects).
    func shelfScreenRect() -> CGRect {
        guard let window = dockView.window, let screen = window.screen ?? NSScreen.screens.first else { return .zero }
        let frame = engine.lastFrame
        let panel = window.frame
        let position = dockView.configuration.position
        let axis = DockAxis(position: position, width: Double(panel.width), height: Double(panel.height))
        let depth = position.isVertical ? Double(panel.width) : Double(panel.height)
        let r = axis.rect(u0: frame.shelfStart - 70, u1: frame.shelfEnd + 70, v0: 0, v1: depth)
        let rect = CGRect(x: panel.minX + r.x, y: panel.minY + r.y, width: r.width, height: r.height).intersection(screen.frame)
        return CGRect(x: rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
#endif
