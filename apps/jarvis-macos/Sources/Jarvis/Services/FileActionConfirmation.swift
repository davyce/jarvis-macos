import AppKit
import Foundation

/// Shows the "first use" confirmation for a file-action capability. Unlike
/// `SystemActionConfirmation` (whose target is a fixed, named UI control),
/// a file action's target is a different path every call -- the handler
/// takes it so the one-time alert can name the actual file being touched,
/// even though `hasConfirmed` still gates by capability, not by call.
enum FileActionConfirmation {
    /// Overridable for tests; defaults to a real `NSAlert` prompt.
    nonisolated(unsafe) static var handler: (FileActionCapability, String) -> Bool = presentAlert

    static func confirm(_ capability: FileActionCapability, target: String) -> Bool {
        handler(capability, target)
    }

    private static func presentAlert(_ capability: FileActionCapability, target: String) -> Bool {
        // File tools run from an async tool-call loop. AppKit must create
        // windows on the main thread or it raises an Objective-C exception.
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                runAlert(capability, target: target)
            }
        }

        var wasAccepted = false
        DispatchQueue.main.sync {
            wasAccepted = MainActor.assumeIsolated {
                runAlert(capability, target: target)
            }
        }
        return wasAccepted
    }

    @MainActor
    private static func runAlert(_ capability: FileActionCapability, target: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Autoriser \u{201C}\(capability.title)\u{201D} ?"
        alert.informativeText = "\(capability.summary)\n\nFichier concerne : \(target)\n\nJarvis ne redemandera pas pour les prochains fichiers, mais tu peux desactiver cette action a tout moment dans Connections > Actions fichiers."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Autoriser")
        alert.addButton(withTitle: "Refuser")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
