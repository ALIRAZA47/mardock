import Foundation

/// Requests the sandboxed app can make of its helper. This enum *is* the
/// helper's whole attack surface: there is no generic "run this" or "write
/// that" operation, and every parameter is validated on arrival.
public enum AgentRequest: Codable, Equatable, Sendable {
    case hello(clientVersion: Int)
    case readSystemDock
    case applySystemDock(changes: [SystemDockChange], restartDock: Bool)
    case importSystemDockApps
    case quitApp(pid: Int32, bundleIdentifier: String, force: Bool)
    case setHidden(pid: Int32, bundleIdentifier: String, hidden: Bool)
    case openTrash
    case verifyIntegrity
    /// Whether the Trash holds anything: its entry count, nothing in it is read.
    case trashState
    /// Whether MarDock may use Accessibility (needed by the three below);
    /// `prompt` asks the user, once.
    case accessibilityStatus(prompt: Bool)
    /// The badges the macOS Dock shows on app icons, such as unread counts.
    case dockBadges
    /// The minimized windows of regular apps: their titles, nothing else.
    case minimizedWindows
    /// Brings back one window: unminimizes it if needed, raises it and
    /// activates its app.
    case showWindow(WindowInfo)
}

public enum AgentReply: Codable, Equatable, Sendable {
    case hello(AgentInfo)
    case systemDock([String: SystemDockValue])
    case importedApps([ImportedDockApp])
    case integrity(IntegrityReport)
    case trash(isFull: Bool)
    case accessibility(trusted: Bool)
    case badges([DockBadge])
    case windows([WindowInfo])
    case done
    case failure(AgentFailure)
}

/// A badge the macOS Dock shows on an app's icon.
public struct DockBadge: Codable, Equatable, Sendable {
    public var bundleIdentifier: String
    public var label: String

    public static let maxCount = 64
    public static let maxLabelLength = 8

    public init(bundleIdentifier: String, label: String) {
        self.bundleIdentifier = bundleIdentifier
        self.label = String(InputValidation.sanitizedDisplayName(label).prefix(Self.maxLabelLength))
    }

    public var isValid: Bool {
        InputValidation.isValidBundleIdentifier(bundleIdentifier) && !label.isEmpty && label.count <= Self.maxLabelLength
    }
}

/// One window of a running app, as the dock shows it.
public struct WindowInfo: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32
    public var bundleIdentifier: String
    public var title: String
    /// Its place in the app's window list when it was read; with the title,
    /// enough to find it again.
    public var index: Int

    public static let maxCount = 32
    public static let maxTitleLength = 80
    public static let maxIndex = 255

    public init(pid: Int32, bundleIdentifier: String, title: String, index: Int) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.title = String(InputValidation.sanitizedDisplayName(title).prefix(Self.maxTitleLength))
        self.index = index
    }

    public var isValid: Bool {
        pid > 1 && InputValidation.isValidBundleIdentifier(bundleIdentifier)
            && title.count <= Self.maxTitleLength && (0...Self.maxIndex).contains(index)
    }
}

public enum AgentFailure: String, Codable, Error, Sendable {
    case invalidRequest
    case notAllowed
    case notFound
    case rateLimited
    case failed
    case unsupportedVersion
}

public struct AgentInfo: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var isSandboxed: Bool
    /// The code requirement every client connection must satisfy.
    public var clientRequirement: String

    public init(protocolVersion: Int, isSandboxed: Bool, clientRequirement: String) {
        self.protocolVersion = protocolVersion
        self.isSandboxed = isSandboxed
        self.clientRequirement = clientRequirement
    }
}

public struct IntegrityReport: Codable, Equatable, Sendable {
    public var appSignatureValid: Bool
    public var helperSignatureValid: Bool
    public var hardenedRuntime: Bool
    public var isAdHoc: Bool
    public var teamIdentifier: String?
    public var signingIdentifier: String?
    public var detail: String

    public init(appSignatureValid: Bool, helperSignatureValid: Bool, hardenedRuntime: Bool, isAdHoc: Bool, teamIdentifier: String?, signingIdentifier: String?, detail: String) {
        self.appSignatureValid = appSignatureValid
        self.helperSignatureValid = helperSignatureValid
        self.hardenedRuntime = hardenedRuntime
        self.isAdHoc = isAdHoc
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.detail = detail
    }
}

/// Encoding used on the XPC connection: bounded JSON.
public enum AgentWire {
    public static let protocolVersion = 2
    public static let maxMessageSize = 64 * 1024

    public enum WireError: Error, Equatable {
        case tooLarge
        case malformed
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maxMessageSize else { throw WireError.tooLarge }
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maxMessageSize else { throw WireError.tooLarge }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WireError.malformed
        }
    }

    /// Validates a decoded request's parameters before it is acted upon.
    public static func isWellFormed(_ request: AgentRequest) -> Bool {
        switch request {
        case let .hello(version):
            return version > 0 && version < 1000
        case .readSystemDock, .importSystemDockApps, .openTrash, .verifyIntegrity,
             .trashState, .accessibilityStatus, .dockBadges, .minimizedWindows:
            return true
        case let .showWindow(window):
            return window.isValid
        case let .applySystemDock(changes, _):
            return SystemDockSchema.isValid(changes)
        case let .quitApp(pid, bundleIdentifier, _), let .setHidden(pid, bundleIdentifier, _):
            return pid > 1 && InputValidation.isValidBundleIdentifier(bundleIdentifier)
        }
    }
}

#if canImport(ObjectiveC)
/// The XPC interface. A single entry point carrying a bounded, validated
/// JSON message keeps the surface small and easy to audit.
@objc public protocol MarDockAgentXPC {
    func handle(_ request: Data, reply: @escaping (Data) -> Void)
}
#endif
