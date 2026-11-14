import AppKit
import Foundation
import Security

public enum RemotePushEnvironment: String, Sendable, Equatable {
    case sandbox
    case production
}

public enum RemotePushAvailability: Sendable, Equatable {
    case available(environment: RemotePushEnvironment)
    case unavailable(reason: String)

    public var environment: RemotePushEnvironment? {
        if case .available(let environment) = self { return environment }
        return nil
    }
}

public enum RemotePushRegistration {
    /// Inspect the running process's signed entitlements, not a source plist or
    /// a preference. An ad-hoc build cannot register merely by adding the key.
    public static func availability() -> RemotePushAvailability {
        guard let task = SecTaskCreateFromSelf(nil) else {
            return .unavailable(reason: "Push signing could not be checked. Live updates remain available while Dayfold is open.")
        }
        let entitlement = SecTaskCopyValueForEntitlement(task, "com.apple.developer.aps-environment" as CFString, nil) as? String
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let flags = values[kSecCodeInfoFlags as String] as? NSNumber else {
            return availability(entitlement: entitlement, isAdHoc: true)
        }
        let isAdHoc = flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0
        return availability(entitlement: entitlement, isAdHoc: isAdHoc)
    }

    /// APNs registration is independent of visible-alert authorization.
    @MainActor @discardableResult
    public static func registerIfAvailable() -> RemotePushAvailability {
        let result = availability()
        if result.environment != nil { NSApplication.shared.registerForRemoteNotifications() }
        return result
    }

    /// Callers upload this value on every successful AppDelegate registration.
    /// Device tokens are opaque bytes; do not assume one historical token size.
    public static func tokenString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func availability(entitlement: String?, isAdHoc: Bool) -> RemotePushAvailability {
        guard !isAdHoc else {
            return .unavailable(reason: "Push notifications require a provisioned app build. Live updates remain available while Dayfold is open.")
        }
        switch entitlement {
        case "development": return .available(environment: .sandbox)
        case "production": return .available(environment: .production)
        default: return .unavailable(reason: "This build does not include push notifications. Live updates remain available while Dayfold is open.")
        }
    }
}
