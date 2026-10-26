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
        guard let app else {
            check("launch", false, "openApplication failed")
            return
        }
        check("launch", true, "pid \(app.processIdentifier)")
        for _ in 0..<50 where !app.isFinishedLaunching {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        app.hide()
        try? await Task.sleep(nanoseconds: 800_000_000)
        check("hide", app.isHidden)
        do {
            try await agent.quit(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier ?? "", force: false)
            for _ in 0..<80 where !app.isTerminated {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            check("quit-via-helper", app.isTerminated)
        } catch {
            check("quit-via-helper", false, error.localizedDescription)
            app.forceTerminate()
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
        let x0 = max(panel.minX + CGFloat(frame.shelfStart) - 70, screen.frame.minX)
        let x1 = min(panel.minX + CGFloat(frame.shelfEnd) + 70, screen.frame.maxX)
        return CGRect(x: x0, y: screen.frame.maxY - panel.maxY, width: max(x1 - x0, 1), height: panel.height)
    }
}
#endif
