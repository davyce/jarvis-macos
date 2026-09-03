import AppKit
import ApplicationServices
import Foundation

/// Wraps macOS's Accessibility (AX) trust check. Every system action that
/// clicks, types, or focuses windows on Jarvis's behalf goes through this
/// gate first, on top of the per-capability permission in
/// `SystemActionPermissionStore`.
enum AccessibilityPermission {
    /// True if this process is currently trusted for Accessibility control,
    /// with no side effects (no prompt).
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// True if trusted. If not, triggers the system's own "Jarvis wants to
    /// control this computer" prompt at most once per app launch (macOS
    /// de-dupes repeat prompts for the same untrusted process on its own),
    /// which adds Jarvis to the Accessibility list in System Settings
    /// (unchecked) so the user just has to flip it on.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        guard !isTrusted else { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings directly on the Accessibility pane so the user
    /// can grant (or double-check) Jarvis's permission.
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
