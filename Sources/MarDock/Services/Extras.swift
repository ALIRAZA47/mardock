import AppKit
import Combine
import CoreGraphics
import MarDockCore

/// Keeps the opt-in extras current while they're on: badges and minimized
/// windows (read by the helper, with Accessibility) and whether the Trash is
/// full. It asks for nothing that's turned off, and stops asking when
/// everything is.
@MainActor
final class ExtrasMonitor: ObservableObject {
    /// Badge labels by tile id.
    @Published private(set) var badges: [String: String] = [:]
    @Published private(set) var minimized: [WindowInfo] = []
    @Published private(set) var trashFull = false
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var screenRecordingAllowed = CGPreflightScreenCaptureAccess()

    private let agent: AgentClient
    private let settings: SettingsStore
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var refreshing = false

    init(agent: AgentClient, settings: SettingsStore) {
        self.agent = agent
        self.settings = settings
    }

    func start() {
        settings.$settings
            .map { [$0.showBadges, $0.showMinimizedWindows, $0.showTrashFull] }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reschedule() }
            .store(in: &cancellables)
        // Windows get minimized and badges change mostly around app switches.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSoon() }
            })
        }
    }

    private var wanted: (badges: Bool, windows: Bool, trash: Bool) {
        let s = settings.settings
        return (s.showBadges, s.showMinimizedWindows, s.showTrashFull)
    }

    private func reschedule() {
        let wanted = self.wanted
        if !wanted.badges { badges = [:] }
        if !wanted.windows { minimized = [] }
        if !wanted.trash { trashFull = false }
        timer?.invalidate()
        timer = nil
        guard wanted.badges || wanted.windows || wanted.trash else { return }
        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.8
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// Soon after something happened, without piling up requests.
    func refreshSoon() {
        guard timer != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        let wanted = self.wanted
        guard wanted.badges || wanted.windows || wanted.trash else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            if wanted.badges || wanted.windows {
                let trusted = (try? await agent.accessibilityTrusted(prompt: false)) ?? false
                if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
            }
            if wanted.badges, accessibilityTrusted, let list = try? await agent.dockBadges() {
                let next = Dictionary(list.map { (DockIdentity.app($0.bundleIdentifier), $0.label) }, uniquingKeysWith: { first, _ in first })
                if next != badges { badges = next }
            }
            if wanted.windows, accessibilityTrusted, let list = try? await agent.minimizedWindows(), list != minimized {
                minimized = list
            }
            if wanted.trash, let full = try? await agent.trashIsFull(), full != trashFull {
                trashFull = full
            }
        }
    }

    /// Shows macOS's request for Accessibility (once; after that it's a
    /// switch in System Settings).
    func requestAccessibility() {
        Task {
            accessibilityTrusted = (try? await agent.accessibilityTrusted(prompt: true)) ?? false
            refreshSoon()
        }
    }

    /// Shows macOS's request for Screen Recording (once).
    func requestScreenRecording() {
        screenRecordingAllowed = CGRequestScreenCaptureAccess()
    }

    /// Re-reads both permissions (the user may have changed them in System Settings).
    func refreshPermissions() {
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        Task {
            accessibilityTrusted = (try? await agent.accessibilityTrusted(prompt: false)) ?? false
        }
    }

    static func openPrivacySettings(_ pane: String) {
        // Only these two panes; the URL is fixed, not built from input.
        let urls = [
            "Accessibility": "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "ScreenCapture": "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        if let string = urls[pane], let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }

    #if MARDOCK_SELFTEST
    /// For the recorded tour, which can't be granted permissions: shows
    /// these as if the helper had read them.
    func demoShow(badges: [String: String], minimized: [WindowInfo], trashFull: Bool) {
        self.badges = badges
        self.minimized = minimized
        self.trashFull = trashFull
    }
    #endif
}
