import AppKit
import MarDockCore

enum UpdaterClientError: LocalizedError, Equatable {
    case unavailable(String)
    case timeout
    case refused(UpdaterFailure)
    case unexpectedReply

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason): return "MarDock's updater isn't available (\(reason))."
        case .timeout: return "The update check took too long."
        case let .refused(failure):
            switch failure {
            case .offline: return "Couldn't reach GitHub. Check your internet connection and try again."
            case .notFound: return "The release's files weren't found on GitHub."
            case .invalidRelease: return "The newest release on GitHub doesn't look right, so MarDock left it alone."
            case .tooLarge: return "The download was larger than any MarDock release should be."
            case .checksumMismatch: return "The download didn't match the release's checksum, so it was thrown away."
            case .rateLimited: return "Checked a moment ago; try again shortly."
            case .invalidRequest, .failed: return "The update check failed."
            }
        case .unexpectedReply: return "The updater sent an unexpected reply."
        }
    }
}

/// Talks to the embedded updater, the only part of MarDock with network
/// access. As with the helper, launchd restricts the connection to this app
/// and the updater's code signature is checked before it's used.
@MainActor
final class UpdaterClient {
    private let serviceName: String
    private var connection: NSXPCConnection?

    init(serviceName: String = AppInfo.updaterServiceName) {
        self.serviceName = serviceName
    }

    /// The newest release, or nil when there's none yet.
    func latestRelease() async throws -> ReleaseInfo? {
        let (reply, _) = try await send(.check, timeout: 45)
        guard case let .release(release) = reply else { throw UpdaterClientError.unexpectedReply }
        guard let release else { return nil }
        guard release.isValid else { throw UpdaterClientError.unexpectedReply }
        return release
    }

    /// Downloads a release's archive, checked against its checksums.
    func download(version: String) async throws -> (sha256: String, archive: FileHandle) {
        let (reply, archive) = try await send(.download(version: version), timeout: 15 * 60)
        guard case let .downloaded(downloaded, sha256) = reply, downloaded == version,
              Checksums.isSHA256(sha256), let archive
        else { throw UpdaterClientError.unexpectedReply }
        return (sha256, archive)
    }

    func send(_ request: UpdaterRequest, timeout: TimeInterval) async throws -> (UpdaterReply, FileHandle?) {
        let payload = try AgentWire.encode(request)
        let connection = connect()
        let (reply, archive): (UpdaterReply, FileHandle?) = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: UpdaterClientError.unavailable(error.localizedDescription))
            }
            guard let updater = proxy as? MarDockUpdaterXPC else {
                once.resume(throwing: UpdaterClientError.unavailable("bad proxy"))
                return
            }
            updater.handle(payload) { data, archive in
                do {
                    once.resume(returning: (try AgentWire.decode(UpdaterReply.self, from: data), archive))
                } catch {
                    once.resume(throwing: UpdaterClientError.unexpectedReply)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                once.resume(throwing: UpdaterClientError.timeout)
            }
        }
        if case let .failure(failure) = reply {
            throw UpdaterClientError.refused(failure)
        }
        return (reply, archive)
    }

    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: MarDockUpdaterXPC.self)
        if let requirement = AgentClient.helperRequirement(serviceName: serviceName) {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.connection = nil } }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}

/// Checks for, downloads and installs updates. Nothing happens unless you
/// ask (Check for Updates) or turn on the daily check; either way the only
/// thing sent is a request for this repository's latest release.
@MainActor
final class UpdateController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(ReleaseInfo)
        case installing(ReleaseInfo)
        case relaunching
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing, .relaunching: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date?
    @Published var checksAutomatically: Bool {
        didSet {
            defaults.set(checksAutomatically, forKey: automaticKey)
            schedule()
        }
    }

    /// Set while MarDock quits to relaunch as the new version.
    private(set) var isRelaunching = false

    private let updater = UpdaterClient()
    private let agent: AgentClient
    private let defaults: UserDefaults
    private var timer: Timer?
    private let automaticKey = "updates.checkAutomatically.v1"
    private let lastCheckedKey = "updates.lastChecked.v1"
    private let announcedKey = "updates.announcedVersion.v1"
    private static let interval: TimeInterval = 24 * 60 * 60

    init(agent: AgentClient, defaults: UserDefaults = .standard) {
        self.agent = agent
        self.defaults = defaults
        checksAutomatically = defaults.bool(forKey: automaticKey)
        lastChecked = defaults.object(forKey: lastCheckedKey) as? Date
    }

    var currentVersion: AppVersion? { AppVersion(AppInfo.version) }

    func start() {
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard checksAutomatically else { return }
        // Look every hour whether a day has passed, so a Mac that sleeps a
        // lot still checks about daily.
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Not straight away at launch: give the dock its moment first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard checksAutomatically, !phase.isBusy else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { return }
        Task { await check(announce: .ifNew) }
    }

    enum Announcement {
        /// Only update the Settings pane.
        case never
        /// A window for a release we haven't told you about yet.
        case ifNew
        /// A window with the outcome, whatever it is (Check for Updates…).
        case always
    }

    func check(announce: Announcement) async {
        guard !phase.isBusy else { return }
        phase = .checking
        let outcome: Phase
        do {
            if let release = try await updater.latestRelease(),
               let latest = AppVersion(release.version), let current = currentVersion, latest > current {
                outcome = .available(release)
            } else {
                outcome = .upToDate
            }
            lastChecked = Date()
            defaults.set(lastChecked, forKey: lastCheckedKey)
        } catch {
            appLog.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            outcome = .failed(error.localizedDescription)
        }
        phase = outcome

        switch (announce, outcome) {
        case let (.always, .available(release)):
            offer(release)
        case let (.ifNew, .available(release)) where defaults.string(forKey: announcedKey) != release.version:
            defaults.set(release.version, forKey: announcedKey)
            offer(release)
        case (.always, .upToDate):
            inform("You’re up to date", "MarDock \(AppInfo.version) is the newest version.")
        case let (.always, .failed(message)):
            inform("Couldn’t check for updates", message)
        default:
            break
        }
    }

    /// Downloads the release, has the helper check and install it, then
    /// relaunches MarDock as the new version.
    func install(_ release: ReleaseInfo) {
        guard !phase.isBusy else { return }
        guard release.installable else {
            openReleasePage(release)
            return
        }
        Task {
            do {
                phase = .downloading(release)
                let (sha256, archive) = try await updater.download(version: release.version)
                phase = .installing(release)
                defer { try? archive.close() }
                try await agent.installUpdate(version: release.version, sha256: sha256, archive: archive)
                relaunch()
            } catch AgentClientError.refused(.notAllowed) {
                phase = .failed("MarDock couldn’t replace itself where it is. Move MarDock to your Applications folder (or allow it under Privacy & Security ▸ App Management), or download the update yourself.")
                inform("Couldn’t install the update", "MarDock couldn’t replace itself where it is. If it isn’t in your Applications folder, move it there first. If macOS asked whether MarDock may update apps, allow it in System Settings ▸ Privacy & Security ▸ App Management. Or download the update from GitHub yourself.", release: release)
            } catch {
                phase = .failed(error.localizedDescription)
                inform("Couldn’t install the update", error.localizedDescription, release: release)
            }
        }
    }

    func openReleasePage(_ release: ReleaseInfo?) {
        let url = release.flatMap { AppVersion($0.version) }.map(UpdateSource.releasePage(for:)) ?? UpdateSource.releasesPage
        NSWorkspace.shared.open(url)
    }

    /// Opens the new copy, which waits for this one to quit (see
    /// `AppDelegate`), then quits.
    private func relaunch() {
        phase = .relaunching
        isRelaunching = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error {
                        appLog.error("Couldn't relaunch: \(error.localizedDescription, privacy: .public)")
                        self.isRelaunching = false
                        self.phase = .failed("Updated. Quit and reopen MarDock to start the new version.")
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    // MARK: Windows

    private func offer(_ release: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "MarDock \(release.version) is available"
        var text = "You have \(AppInfo.version)."
        // The release page starts with download instructions; what changed
        // is the part worth showing here.
        let notes = release.notes.range(of: "## What's Changed").map { String(release.notes[$0.lowerBound...]) } ?? release.notes
        if !notes.isEmpty {
            text += "\n\n" + String(notes.prefix(600)) + (notes.count > 600 ? "…" : "")
        }
        if !release.installable {
            text += "\n\nThis release has to be downloaded from GitHub."
        }
        alert.informativeText = text
        alert.addButton(withTitle: release.installable ? "Install and Relaunch" : "Open Release Page")
        alert.addButton(withTitle: "Later")
        if release.installable { alert.addButton(withTitle: "Release Notes") }
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: openReleasePage(release)
        default: break
        }
    }

    private func inform(_ title: String, _ message: String, release: ReleaseInfo? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if release != nil { alert.addButton(withTitle: "Open Release Page") }
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            openReleasePage(release)
        }
    }
}
