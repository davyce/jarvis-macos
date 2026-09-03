import AppKit
import Foundation

/// Shows the "first use" confirmation for a system action capability. The
/// handler is swappable so tests can simulate accept/decline without driving
/// a real modal dialog.
enum SystemActionConfirmation {
    /// Overridable for tests; defaults to a real `NSAlert` prompt.
    nonisolated(unsafe) static var handler: (SystemActionCapability) -> Bool = presentAlert

    static func confirm(_ capability: SystemActionCapability) -> Bool {
        handler(capability)
    }

    private static func presentAlert(_ capability: SystemActionCapability) -> Bool {
        // System actions run from the same async loop. Keep AppKit window
        // creation on the main thread so first-use confirmation cannot crash.
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                runAlert(capability)
            }
        }

        var wasAccepted = false
        DispatchQueue.main.sync {
            wasAccepted = MainActor.assumeIsolated {
                runAlert(capability)
            }
        }
        return wasAccepted
    }

    @MainActor
    private static func runAlert(_ capability: SystemActionCapability) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Autoriser \u{201C}\(capability.title)\u{201D} ?"
        alert.informativeText = "\(capability.summary)\n\nCible : \(capability.targetDescription)\n\nJarvis ne redemandera pas la prochaine fois, mais tu peux desactiver cette action a tout moment dans Connections > Actions systeme."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Autoriser")
        alert.addButton(withTitle: "Refuser")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
