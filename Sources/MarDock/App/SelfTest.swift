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

        // 6. Launch, hide and quit a real app.
        await launchHideQuit(agent: agent)

        // 7. The renderer survives a full frame in every theme.
        renderSmokeTest()

        return failures == 0
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

        // Hiding a background app through the helper.
        if (try? await agent.setHidden(pid: app.processIdentifier, bundleIdentifier: identifier, hidden: true)) != nil {
            let hidden = await waitUntil(2) { app.isHidden }
            info("hide-background-via-helper", "hidden \(hidden)")
            _ = try? await agent.setHidden(pid: app.processIdentifier, bundleIdentifier: identifier, hidden: false)
            _ = await waitUntil(2) { !app.isHidden }
        } else {
            info("hide-background-via-helper", "request failed")
        }

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

        // What the sandbox allows directly (informational).
        let directHide = app.hide()
        let hiddenDirectly = await waitUntil(1) { app.isHidden }
        info("hide-direct", "returned \(directHide), hidden \(hiddenDirectly)")
        if hiddenDirectly {
            _ = app.unhide()
            _ = await waitUntil(1) { !app.isHidden }
        }

        do {
            try await agent.setHidden(pid: app.processIdentifier, bundleIdentifier: identifier, hidden: true)
            check("hide-via-helper", await waitUntil(2) { app.isHidden })
            try await agent.setHidden(pid: app.processIdentifier, bundleIdentifier: identifier, hidden: false)
            check("unhide-via-helper", await waitUntil(2) { !app.isHidden })
        } catch {
            check("hide-via-helper", false, error.localizedDescription)
        }

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
        coordinator.pins.setPins(PinStore.defaultPins())
        if arguments.contains("--backdrop") {
            showBackdrop()
        }
        coordinator.running.start()
        coordinator.dock.start()
        coordinator.dock.stopPointerTracking()

        switch value("--window") {
        case "settings":
            coordinator.showSettings()
            reportWindow(titled: "MarDock Settings")
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

    private static var backdrop: NSWindow?

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

extension DockController {
    /// Places a pretend pointer over the dock (0 = first tile, 1 = last).
    func simulatePointer(fraction: Double) {
        let frame = engine.lastFrame
        let u = frame.shelfStart + (frame.shelfEnd - frame.shelfStart) * min(max(fraction, 0), 1)
        engine.setPointer(DockPointer(u: u, v: engine.metrics.edgeGap + engine.metrics.shelfThickness / 2))
        for _ in 0..<90 { dockView.apply(engine.tick(1.0 / 60)) }
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
