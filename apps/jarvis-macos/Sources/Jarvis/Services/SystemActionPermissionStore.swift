import Foundation

/// Per-capability permission state for system actions: whether a capability
/// is enabled at all, and whether the user has already confirmed it once.
///
/// Every capability starts disabled. Enabling one is a deliberate opt-in
/// (Connections > Actions systeme); even once enabled, the first execution
/// still requires an explicit confirmation (see `SystemActionConfirmation`)
/// before anything runs silently.
final class SystemActionPermissionStore: @unchecked Sendable {
    static let shared = SystemActionPermissionStore()

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.adansonia.jarvis.systemActionPermissions")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isEnabled(_ capability: SystemActionCapability) -> Bool {
        queue.sync { defaults.bool(forKey: enabledKey(capability)) }
    }

    func setEnabled(_ enabled: Bool, for capability: SystemActionCapability) {
        queue.sync {
            defaults.set(enabled, forKey: enabledKey(capability))
            if !enabled {
                defaults.set(false, forKey: confirmedKey(capability))
            }
        }
    }

    func hasConfirmed(_ capability: SystemActionCapability) -> Bool {
        queue.sync { defaults.bool(forKey: confirmedKey(capability)) }
    }

    func markConfirmed(_ capability: SystemActionCapability) {
        queue.sync { defaults.set(true, forKey: confirmedKey(capability)) }
    }

    /// Test/debug hook to reset a capability back to its untouched state.
    func reset(_ capability: SystemActionCapability) {
        queue.sync {
            defaults.removeObject(forKey: enabledKey(capability))
            defaults.removeObject(forKey: confirmedKey(capability))
        }
    }

    private func enabledKey(_ capability: SystemActionCapability) -> String {
        "jarvis.systemAction.\(capability.rawValue).enabled"
    }

    private func confirmedKey(_ capability: SystemActionCapability) -> String {
        "jarvis.systemAction.\(capability.rawValue).confirmed"
    }
}
