import Foundation
import MarDockCore

enum AgentClientError: LocalizedError, Equatable {
    case unavailable(String)
    case timeout
    case refused(AgentFailure)
    case unexpectedReply

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason): return "The MarDock helper isn't available (\(reason))."
        case .timeout: return "The MarDock helper didn't respond in time."
        case let .refused(failure):
            switch failure {
            case .notAllowed: return "That isn't allowed."
            case .notFound: return "That app is no longer running."
            case .rateLimited: return "Too many requests; try again in a moment."
            case .invalidRequest: return "The request was rejected as invalid."
            case .unsupportedVersion: return "The helper is from a different version of MarDock."
            case .failed: return "The operation failed."
            }
        case .unexpectedReply: return "The helper sent an unexpected reply."
        }
    }
}

/// Talks to the embedded XPC helper. The connection itself is restricted by
/// launchd to this app; on top of that the helper's code signature is checked
/// against a requirement derived from our own signature.
@MainActor
final class AgentClient {
    private let serviceName: String
    private var connection: NSXPCConnection?

    init(serviceName: String = AppInfo.agentServiceName) {
        self.serviceName = serviceName
    }

    // MARK: Operations

    func hello() async throws -> AgentInfo {
        guard case let .hello(info) = try await send(.hello(clientVersion: AgentWire.protocolVersion)) else {
            throw AgentClientError.unexpectedReply
        }
        return info
    }

    func readSystemDock() async throws -> [String: SystemDockValue] {
        guard case let .systemDock(values) = try await send(.readSystemDock) else { throw AgentClientError.unexpectedReply }
        return values
    }

    func applySystemDock(_ changes: [SystemDockChange], restartDock: Bool) async throws {
        try await expectDone(.applySystemDock(changes: changes, restartDock: restartDock))
    }

    func importSystemDockApps() async throws -> [ImportedDockApp] {
        guard case let .importedApps(apps) = try await send(.importSystemDockApps) else { throw AgentClientError.unexpectedReply }
        return apps
    }

    func quit(pid: pid_t, bundleIdentifier: String, force: Bool) async throws {
        try await expectDone(.quitApp(pid: pid, bundleIdentifier: bundleIdentifier, force: force))
    }

    func setHidden(pid: pid_t, bundleIdentifier: String, hidden: Bool) async throws {
        try await expectDone(.setHidden(pid: pid, bundleIdentifier: bundleIdentifier, hidden: hidden))
    }

    func openTrash() async throws {
        try await expectDone(.openTrash)
    }

    func verifyIntegrity() async throws -> IntegrityReport {
        guard case let .integrity(report) = try await send(.verifyIntegrity, timeout: 20) else { throw AgentClientError.unexpectedReply }
        return report
    }

    // MARK: Transport

    private func expectDone(_ request: AgentRequest) async throws {
        guard case .done = try await send(request) else { throw AgentClientError.unexpectedReply }
    }

    func send(_ request: AgentRequest, timeout: TimeInterval = 6) async throws -> AgentReply {
        let payload = try AgentWire.encode(request)
        let connection = connect()
        let reply: AgentReply = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: AgentClientError.unavailable(error.localizedDescription))
            }
            guard let agent = proxy as? MarDockAgentXPC else {
                once.resume(throwing: AgentClientError.unavailable("bad proxy"))
                return
            }
            agent.handle(payload) { data in
                do {
                    once.resume(returning: try AgentWire.decode(AgentReply.self, from: data))
                } catch {
                    once.resume(throwing: AgentClientError.unexpectedReply)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                once.resume(throwing: AgentClientError.timeout)
            }
        }
        if case let .failure(failure) = reply {
            throw AgentClientError.refused(failure)
        }
        return reply
    }

    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: MarDockAgentXPC.self)
        if let requirement = Self.helperRequirement(serviceName: serviceName) {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.connection = nil } }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    /// The helper must carry its expected identifier, and — when MarDock is
    /// signed with a Developer ID — the same team identifier as the app.
    static func helperRequirement(serviceName: String) -> String? {
        guard InputValidation.isValidBundleIdentifier(serviceName) else { return nil }
        let me = CodeSignature.inspectSelf()
        if !me.isAdHoc, let team = me.teamIdentifier,
           !team.isEmpty, team.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
            return "identifier \"\(serviceName)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        return "identifier \"\(serviceName)\""
    }
}

/// Makes sure a continuation is resumed exactly once (reply, error or timeout).
private final class ResumeOnce<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }
}
