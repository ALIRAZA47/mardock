import AppKit
import Foundation
import MarDockCore
import os

let agentLog = Logger(subsystem: "MarDockAgent", category: "agent")

final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let gate: ClientGate
    private let limiter: RateLimiter

    init(gate: ClientGate, limiter: RateLimiter) {
        self.gate = gate
        self.limiter = limiter
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement = gate.clientRequirement else {
            agentLog.error("Refusing connection: \(self.gate.reason, privacy: .public)")
            return false
        }
        // The system checks the peer against this requirement and invalidates
        // the connection if it doesn't match.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: MarDockAgentXPC.self)
        connection.exportedObject = AgentService(gate: gate, limiter: limiter, clientPID: connection.processIdentifier)
        connection.resume()
        return true
    }
}

final class AgentService: NSObject, MarDockAgentXPC, @unchecked Sendable {
    private let gate: ClientGate
    private let limiter: RateLimiter
    private let clientPID: pid_t

    init(gate: ClientGate, limiter: RateLimiter, clientPID: pid_t) {
        self.gate = gate
        self.limiter = limiter
        self.clientPID = clientPID
    }

    func handle(_ request: Data, reply: @escaping (Data) -> Void) {
        guard let decoded = try? AgentWire.decode(AgentRequest.self, from: request),
              AgentWire.isWellFormed(decoded)
        else {
            agentLog.error("Rejected a malformed request")
            reply(Self.encode(.failure(.invalidRequest)))
            return
        }
        DispatchQueue.main.async {
            // Accessibility work can wait on a busy app: it runs on its own
            // queue so it never holds up quitting or hiding.
            if let slow = self.accessibilityWork(for: decoded) {
                WindowAccess.queue.async { reply(Self.encode(slow())) }
            } else {
                reply(Self.encode(self.perform(decoded)))
            }
        }
    }

    func install(_ request: Data, archive: FileHandle, reply: @escaping (Data) -> Void) {
        guard let decoded = try? AgentWire.decode(AgentRequest.self, from: request),
              AgentWire.isWellFormed(decoded),
              case let .installUpdate(version, sha256) = decoded
        else {
            agentLog.error("Rejected a malformed install request")
            reply(Self.encode(.failure(.invalidRequest)))
            return
        }
        DispatchQueue.main.async {
            guard self.limiter.allow("install", every: 10) else {
                reply(Self.encode(.failure(.rateLimited)))
                return
            }
            guard let app = self.gate.appURL, let identifier = self.gate.appBundleIdentifier else {
                reply(Self.encode(.failure(.notAllowed)))
                return
            }
            // Checking signatures and extracting take a few seconds.
            UpdateInstaller.queue.async {
                let result = UpdateInstaller.install(archive: archive, version: version, sha256: sha256, appURL: app, bundleIdentifier: identifier)
                try? archive.close()
                reply(Self.encode(result))
            }
        }
    }

    private var ownBundleIdentifiers: [String] {
        [gate.appBundleIdentifier, Bundle.main.bundleIdentifier].compactMap { $0?.lowercased() }
    }

    /// The checks for the Accessibility requests happen here, on the main
    /// queue; the returned work runs on `WindowAccess.queue`. Nil for every
    /// other request.
    private func accessibilityWork(for request: AgentRequest) -> (() -> AgentReply)? {
        switch request {
        case .dockBadges:
            guard limiter.allow("badges", every: 0.8) else { return { .failure(.rateLimited) } }
            guard WindowAccess.isTrusted else { return { .failure(.notAllowed) } }
            guard let dock = DockPreferences.runningDocks().first else {
                return { .failure(.notFound) }
            }
            let pid = dock.processIdentifier
            return { .badges(WindowAccess.badges(dockPID: pid)) }

        case .minimizedWindows:
            guard limiter.allow("windows", every: 0.8) else { return { .failure(.rateLimited) } }
            guard WindowAccess.isTrusted else { return { .failure(.notAllowed) } }
            // The same apps quitting is allowed for: never part of macOS (so
            // not Finder's windows either) and never us.
            let excluded = AppTerminator.protectedBundleIdentifiers.union(ownBundleIdentifiers)
            let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (pid: pid_t, bundleIdentifier: String)? in
                guard app.activationPolicy == .regular, !app.isTerminated, app.processIdentifier != self.clientPID,
                      let identifier = app.bundleIdentifier, !excluded.contains(identifier.lowercased())
                else { return nil }
                return (app.processIdentifier, identifier)
            }
            return { .windows(WindowAccess.minimizedWindows(of: apps)) }

        case let .showWindow(target):
            guard limiter.allow("show:\(target.pid)", every: 0.2) else { return { .failure(.rateLimited) } }
            guard WindowAccess.isTrusted else { return { .failure(.notAllowed) } }
            // The pid must still belong to the app the dock thinks it is, a
            // regular app, and — as for quitting — never part of macOS or us.
            guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
                  let actual = app.bundleIdentifier,
                  actual.caseInsensitiveCompare(target.bundleIdentifier) == .orderedSame,
                  app.activationPolicy == .regular,
                  target.pid != clientPID, target.pid != getpid(),
                  !AppTerminator.protectedBundleIdentifiers.contains(actual.lowercased()),
                  !ownBundleIdentifiers.contains(actual.lowercased())
            else { return { .failure(.notAllowed) } }
            return { WindowAccess.show(target) }

        default:
            return nil
        }
    }

    /// A reply that doesn't fit the wire becomes a failure the app can show,
    /// never empty data it can only shrug at.
    private static func encode(_ reply: AgentReply) -> Data {
        if let data = try? AgentWire.encode(reply) { return data }
        agentLog.error("A reply didn't fit the wire; sending a failure instead")
        return (try? AgentWire.encode(AgentReply.failure(.failed))) ?? Data()
    }

    private func perform(_ request: AgentRequest) -> AgentReply {
        switch request {
        case let .hello(version):
            guard version == AgentWire.protocolVersion else { return .failure(.unsupportedVersion) }
            return .hello(AgentInfo(
                protocolVersion: AgentWire.protocolVersion,
                isSandboxed: ProcessSecurity.isSandboxed,
                clientRequirement: gate.clientRequirement ?? ""
            ))

        case .readSystemDock:
            return .systemDock(DockPreferences.read())

        case let .applySystemDock(changes, restartDock):
            guard limiter.allow("apply", every: 0.4) else { return .failure(.rateLimited) }
            guard DockPreferences.write(changes) else { return .failure(.failed) }
            agentLog.info("Applied \(changes.count) Dock preference change(s)")
            if restartDock, limiter.allow("restart", every: 1.5) {
                DockPreferences.restartDock()
            }
            return .done

        case .importSystemDockApps:
            return AgentWire.importedApps(fitting: DockPreferences.pinnedApps())

        case let .quitApp(pid, bundleIdentifier, force):
            guard limiter.allow("quit:\(pid)", every: 0.3) else { return .failure(.rateLimited) }
            return AppTerminator.quit(
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                force: force,
                clientPID: clientPID,
                ownBundleIdentifiers: ownBundleIdentifiers
            )

        case let .setHidden(pid, bundleIdentifier, hidden):
            guard limiter.allow("hide:\(pid)", every: 0.15) else { return .failure(.rateLimited) }
            return AppTerminator.setHidden(
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                hidden: hidden,
                clientPID: clientPID,
                ownBundleIdentifiers: ownBundleIdentifiers
            )

        case .openTrash:
            guard limiter.allow("trash", every: 0.8) else { return .failure(.rateLimited) }
            let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
            return NSWorkspace.shared.open(trash) ? .done : .failure(.failed)

        case .trashState:
            guard limiter.allow("trashState", every: 0.5) else { return .failure(.rateLimited) }
            return TrashStatus.isFull().map { .trash(isFull: $0) } ?? .failure(.failed)

        case let .accessibilityStatus(prompt):
            if prompt {
                guard limiter.allow("prompt", every: 2) else { return .failure(.rateLimited) }
                return .accessibility(trusted: WindowAccess.requestTrust())
            }
            return .accessibility(trusted: WindowAccess.isTrusted)

        case .dockBadges, .minimizedWindows, .showWindow:
            // Handled by `accessibilityWork(for:)`.
            return .failure(.invalidRequest)

        case .installUpdate:
            // Only with its archive, through `install(_:archive:reply:)`.
            return .failure(.invalidRequest)

        case .verifyIntegrity:
            guard limiter.allow("verify", every: 2) else { return .failure(.rateLimited) }
            let app = gate.appURL.map { CodeSignature.inspect(bundleAt: $0) }
            let helper = CodeSignature.inspect(bundleAt: Bundle.main.bundleURL)
            return .integrity(IntegrityReport(
                appSignatureValid: app?.isValid ?? false,
                helperSignatureValid: helper.isValid,
                hardenedRuntime: (app?.hasHardenedRuntime ?? false) && helper.hasHardenedRuntime,
                isAdHoc: app?.isAdHoc ?? true,
                teamIdentifier: app?.teamIdentifier,
                signingIdentifier: app?.identifier,
                detail: app?.status ?? gate.reason
            ))
        }
    }
}
