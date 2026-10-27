#if os(macOS)
import Foundation
import Security

/// What the code-signing system says about a piece of code.
public struct CodeSignatureInfo: Equatable, Sendable {
    public var isValid: Bool
    public var identifier: String?
    public var teamIdentifier: String?
    public var isAdHoc: Bool
    public var hasHardenedRuntime: Bool
    /// The requirement any copy of this code satisfies (for an ad-hoc
    /// signature this pins the exact code hash).
    public var designatedRequirement: String?
    public var status: String

    static func failure(_ status: OSStatus) -> CodeSignatureInfo {
        CodeSignatureInfo(isValid: false, identifier: nil, teamIdentifier: nil, isAdHoc: false, hasHardenedRuntime: false,
                          designatedRequirement: nil, status: CodeSignature.message(for: status))
    }
}

public enum CodeSignature {
    private static let adHocFlag: UInt32 = 0x0002 // kSecCodeSignatureAdhoc
    private static let runtimeFlag: UInt32 = 0x10000 // kSecCodeSignatureRuntime

    /// Validates the bundle at `url` (all architectures, nested code, strict)
    /// and describes its signature.
    public static func inspect(bundleAt url: URL) -> CodeSignatureInfo {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard created == errSecSuccess, let staticCode else { return .failure(created) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(staticCode, flags, nil)
        return describe(staticCode, status: status)
    }

    /// Describes the running process's own signature.
    public static func inspectSelf() -> CodeSignatureInfo {
        var code: SecCode?
        let copied = SecCodeCopySelf(SecCSFlags(), &code)
        guard copied == errSecSuccess, let code else { return .failure(copied) }
        var staticCode: SecStaticCode?
        let converted = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
        guard converted == errSecSuccess, let staticCode else { return .failure(converted) }
        return describe(staticCode, status: SecCodeCheckValidity(code, SecCSFlags(), nil))
    }

    static func message(for status: OSStatus) -> String {
        if status == errSecSuccess { return "Valid" }
        return (SecCopyErrorMessageString(status, nil) as String?) ?? "Error \(status)"
    }

    private static func describe(_ code: SecStaticCode, status: OSStatus) -> CodeSignatureInfo {
        var rawInfo: CFDictionary?
        _ = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo)
        let info = (rawInfo as? [String: Any]) ?? [:]
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0

        var requirement: SecRequirement?
        var requirementText: CFString?
        if SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement) == errSecSuccess, let requirement {
            _ = SecRequirementCopyString(requirement, SecCSFlags(), &requirementText)
        }

        return CodeSignatureInfo(
            isValid: status == errSecSuccess,
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
            isAdHoc: flags & adHocFlag != 0,
            hasHardenedRuntime: flags & runtimeFlag != 0,
            designatedRequirement: requirementText as String?,
            status: message(for: status)
        )
    }
}

public enum ProcessSecurity {
    /// True when the current process runs inside the App Sandbox.
    public static var isSandboxed: Bool {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil { return true }
        // Inside the sandbox the home directory is the app's container.
        return NSHomeDirectory().contains("/Library/Containers/")
    }

    /// Reads one of the current process's entitlements.
    public static func entitlement(_ name: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, name as CFString, nil)
    }

    public static func hasEntitlement(_ name: String) -> Bool {
        (entitlement(name) as? Bool) == true
    }
}
#endif
