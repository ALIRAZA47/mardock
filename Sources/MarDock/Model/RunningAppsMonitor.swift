import AppKit
import Combine
import MarDockCore

/// Tracks running apps through NSWorkspace notifications: which are running,
/// frontmost, hidden or still launching.
@MainActor
final class RunningAppsMonitor: ObservableObject {
    @Published private(set) var snapshots: [RunningAppSnapshot] = []
    /// Tiles that should bounce: apps still launching, plus launches the user
    /// just asked for that macOS hasn't reported yet.
    @Published private(set) var launching: Set<String> = []

    private var appsByKey: [String: NSRunningApplication] = [:]
    private var launchOrder: [pid_t: Int] = [:]
    private var nextOrder = 0
    private var observers: [NSObjectProtocol] = []
    private var listObservation: NSKeyValueObservation?
    private var launchObservations: [pid_t: NSKeyValueObservation] = [:]
    private var requestedLaunches: [String: Date] = [:]
    private var refreshPending = false
    private var expiryTimer: Timer?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.willLaunchApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        listObservation = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.scheduleRefresh() } }
        }
        refresh()
    }

    func runningApp(for key: String) -> NSRunningApplication? {
        appsByKey[key]
    }

    /// The user asked to launch an app: bounce right away.
    func noteLaunchRequested(_ key: String) {
        requestedLaunches[key] = Date()
        updateLaunching()
        scheduleExpiry()
    }

    func noteLaunchFailed(_ key: String) {
        requestedLaunches[key] = nil
        updateLaunching()
    }

    static func key(for app: NSRunningApplication) -> String {
        if let identifier = app.bundleIdentifier, InputValidation.isValidBundleIdentifier(identifier) {
            return DockIdentity.app(identifier)
        }
        return DockIdentity.process(app.processIdentifier)
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    func refresh() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var byKey: [String: RunningAppSnapshot] = [:]
        var apps: [String: NSRunningApplication] = [:]
        var order: [String] = []
        var livePIDs = Set<pid_t>()

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
            let pid = app.processIdentifier
            livePIDs.insert(pid)
            if launchOrder[pid] == nil {
                launchOrder[pid] = nextOrder
                nextOrder += 1
            }
            observeLaunchCompletion(of: app)

            let key = Self.key(for: app)
            let isActive = app.isActive || pid == frontmost
            if var existing = byKey[key] {
                // Several instances of one app share a tile.
                existing.isActive = existing.isActive || isActive
                existing.isHidden = existing.isHidden && app.isHidden
                existing.isFinishedLaunching = existing.isFinishedLaunching || app.isFinishedLaunching
                byKey[key] = existing
            } else {
                let name = InputValidation.sanitizedDisplayName(app.localizedName ?? app.bundleIdentifier ?? "App")
                byKey[key] = RunningAppSnapshot(
                    key: key,
                    bundleIdentifier: app.bundleIdentifier,
                    pid: pid,
                    name: name,
                    isActive: isActive,
                    isHidden: app.isHidden,
                    isFinishedLaunching: app.isFinishedLaunching,
                    order: launchOrder[pid] ?? 0
                )
                apps[key] = app
                order.append(key)
            }
        }

        launchOrder = launchOrder.filter { livePIDs.contains($0.key) }
        for pid in launchObservations.keys where !livePIDs.contains(pid) {
            launchObservations[pid] = nil
        }
        appsByKey = apps

        let updated = order.compactMap { byKey[$0] }
        if updated != snapshots {
            snapshots = updated
        }
        for key in requestedLaunches.keys where byKey[key]?.isFinishedLaunching == true {
            requestedLaunches[key] = nil
        }
        updateLaunching()
    }

    private func observeLaunchCompletion(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !app.isFinishedLaunching, launchObservations[pid] == nil else { return }
        launchObservations[pid] = app.observe(\.isFinishedLaunching, options: []) { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.scheduleRefresh() } }
        }
    }

    private func updateLaunching() {
        var keys = Set(requestedLaunches.keys)
        for snapshot in snapshots where !snapshot.isFinishedLaunching {
            keys.insert(snapshot.key)
        }
        if keys != launching {
            launching = keys
        }
    }

    /// Requested launches that never materialise stop bouncing after a while.
    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let cutoff = Date().addingTimeInterval(-25)
                self.requestedLaunches = self.requestedLaunches.filter { $0.value > cutoff }
                self.updateLaunching()
                if self.requestedLaunches.isEmpty {
                    timer.invalidate()
                }
            }
        }
    }
}
