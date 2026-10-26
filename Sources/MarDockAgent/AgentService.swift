import AppKit
import Foundation
import MarDockCore
import os

let agentLog = Logger(subsystem: "MarDockAgent", category: "agent")

/// Decides who may talk to the agent: only processes that satisfy the
/// designated requirement of the app bundle this service is embedded in.
/// For a Developer ID build that is "same identifier, same team"; for an
/// ad-hoc local build it is the app's exact code hash. If the containing app
/// fails signature validation, every connection is refused (fail closed).
final class ClientGate: @unchecked Sendable {
    let appURL: URL?
    let appBundleIdentifier: String?
    let clientRequirement: String?
    let reason: String

    init(agentBundleURL: URL = Bundle.main.bundleURL) {
        // …/MarDock.app/Contents/XPCServices/<agent>.xpc
        let app = agentBundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard agentBundleURL.pathExtension == "xpc", app.pathExtension == "app" else {
            appURL = nil
            appBundleIdentifier = nil
            clientRequirement = nil
            reason = "Not embedded in an app bundle"
            return
        }
        appURL = app
        appBundleIdentifier = Bundle(url: app)?.bundleIdentifier
        let signature = CodeSignature.inspect(bundleAt: app)
        if signature.isValid, let requirement = signature.designatedRequirement, !requirement.isEmpty {
            clientRequirement = requirement
            reason = "OK"
        } else {
            clientRequirement = nil
            reason = "Containing app failed validation: \(signature.status)"
        }
    }
}

/// Simple per-operation throttle. Only touched on the main queue.
final class RateLimiter: @unchecked Sendable {
    private var last: [String: Date] = [:]

    func allow(_ operation: String, every interval: TimeInterval) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = Date()
        if let previous = last[operation], now.timeIntervalSince(previous) < interval {
            return false
        }
        last[operation] = now
        return true
    }
}

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
            reply(Self.encode(self.perform(decoded)))
        }
    }

    private static func encode(_ reply: AgentReply) -> Data {
        (try? AgentWire.encode(reply)) ?? Data()
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
            return .importedApps(DockPreferences.pinnedApps())

        case let .quitApp(pid, bundleIdentifier, force):
            guard limiter.allow("quit:\(pid)", every: 0.3) else { return .failure(.rateLimited) }
            return AppTerminator.quit(
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                force: force,
                clientPID: clientPID,
                ownBundleIdentifiers: [gate.appBundleIdentifier, Bundle.main.bundleIdentifier].compactMap { $0?.lowercased() }
            )

        case .openTrash:
            guard limiter.allow("trash", every: 0.8) else { return .failure(.rateLimited) }
            let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
            return NSWorkspace.shared.open(trash) ? .done : .failure(.failed)

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
