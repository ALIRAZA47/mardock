#if os(macOS)
import Foundation

/// Decides who may talk to one of MarDock's XPC services (the helper or the
/// updater): only processes that satisfy the designated requirement of the
/// app bundle the service is embedded in. For a Developer ID build that is "same identifier, same team"; for an
/// ad-hoc local build it is the app's exact code hash. If the containing app
/// fails signature validation, every connection is refused (fail closed).
public final class ClientGate: @unchecked Sendable {
    public let appURL: URL?
    public let appBundleIdentifier: String?
    public let clientRequirement: String?
    public let reason: String

    fileprivate init(appURL: URL?, appBundleIdentifier: String?, clientRequirement: String?, reason: String) {
        self.appURL = appURL
        self.appBundleIdentifier = appBundleIdentifier
        self.clientRequirement = clientRequirement
        self.reason = reason
    }

    public init(serviceBundleURL: URL = Bundle.main.bundleURL) {
        // …/MarDock.app/Contents/XPCServices/<service>.xpc
        let app = serviceBundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard serviceBundleURL.pathExtension == "xpc", app.pathExtension == "app" else {
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

extension ClientGate {
    /// For a sandboxed service (the updater), which can't read the app it's
    /// embedded in and so can't learn that app's exact requirement: the
    /// client must carry the app's identifier (this service's, less
    /// `suffix`) and, when this service is signed with a Developer ID, be
    /// signed by the same team. launchd already lets only the containing app
    /// look the service up; this is the second lock.
    public static func sandboxedService(suffix: String) -> ClientGate {
        let me = CodeSignature.inspectSelf()
        guard me.isValid, let own = Bundle.main.bundleIdentifier, own.hasSuffix(suffix) else {
            return ClientGate(appBundleIdentifier: nil, clientRequirement: nil, reason: "This service's own signature didn't validate")
        }
        let app = String(own.dropLast(suffix.count))
        guard InputValidation.isValidBundleIdentifier(app) else {
            return ClientGate(appBundleIdentifier: nil, clientRequirement: nil, reason: "Unexpected identifier")
        }
        var requirement = "identifier \"\(app)\""
        if !me.isAdHoc, let team = me.teamIdentifier, !team.isEmpty,
           team.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) {
            requirement += " and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        return ClientGate(appBundleIdentifier: app, clientRequirement: requirement, reason: "OK")
    }

    private convenience init(appBundleIdentifier: String?, clientRequirement: String?, reason: String) {
        self.init(appURL: nil, appBundleIdentifier: appBundleIdentifier, clientRequirement: clientRequirement, reason: reason)
    }
}

/// Simple per-operation throttle. Only touched on the main queue.
public final class RateLimiter: @unchecked Sendable {
    private var last: [String: Date] = [:]

    public init() {}

    public func allow(_ operation: String, every interval: TimeInterval) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = Date()
        if let previous = last[operation], now.timeIntervalSince(previous) < interval {
            return false
        }
        last[operation] = now
        return true
    }
}
#endif
