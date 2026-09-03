import Foundation

/// Per-capability permission state for file actions -- structurally
/// identical to `SystemActionPermissionStore`, kept as its own type rather
/// than a shared generic (mirrors this codebase's existing precedent of
/// `SystemActionAuditEntry`/`LimuleBridgeAuditEntry` staying separate,
/// differently-shaped schemas unified only at the `AuditTrailEntry` layer).
///
/// Every capability starts disabled. Enabling one is a deliberate opt-in
/// (Connections > Actions fichiers); even once enabled, the first
/// execution still requires an explicit confirmation naming the actual
/// file (see `FileActionConfirmation`) before anything runs silently.
final class FileActionPermissionStore: @unchecked Sendable {
    static let shared = FileActionPermissionStore()

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.adansonia.jarvis.fileActionPermissions")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isEnabled(_ capability: FileActionCapability) -> Bool {
        queue.sync { defaults.bool(forKey: enabledKey(capability)) }
    }

    func setEnabled(_ enabled: Bool, for capability: FileActionCapability) {
        queue.sync {
            defaults.set(enabled, forKey: enabledKey(capability))
            if !enabled {
                defaults.set(false, forKey: confirmedKey(capability))
            }
        }
    }

    func hasConfirmed(_ capability: FileActionCapability) -> Bool {
        queue.sync { defaults.bool(forKey: confirmedKey(capability)) }
    }

    func markConfirmed(_ capability: FileActionCapability) {
        queue.sync { defaults.set(true, forKey: confirmedKey(capability)) }
    }

    /// Test/debug hook to reset a capability back to its untouched state.
    func reset(_ capability: FileActionCapability) {
        queue.sync {
            defaults.removeObject(forKey: enabledKey(capability))
            defaults.removeObject(forKey: confirmedKey(capability))
        }
    }

    private func enabledKey(_ capability: FileActionCapability) -> String {
        "jarvis.fileAction.\(capability.rawValue).enabled"
    }

    private func confirmedKey(_ capability: FileActionCapability) -> String {
        "jarvis.fileAction.\(capability.rawValue).confirmed"
    }
}
