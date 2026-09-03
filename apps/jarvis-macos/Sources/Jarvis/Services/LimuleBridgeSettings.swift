import Foundation

/// A single master switch for all LIMULE Bridge access -- not a per-action
/// confirmation (Bridge has none, and none is added here by design; the
/// Suivi audit trail is the safety net instead), just one visible, easy
/// place to turn the entire surface off. Defaults to disabled.
enum LimuleBridgeSettings {
    private static let enabledKey = "jarvis.limuleBridge.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}
