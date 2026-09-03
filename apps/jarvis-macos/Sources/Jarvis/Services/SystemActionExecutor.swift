import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Low-level implementations of the scoped system-action capabilities, using
/// the macOS Accessibility API (AXUIElement) to find and press named
/// controls / focus windows, and CGEvent to synthesize keystrokes. Callers
/// never pass raw coordinates or arbitrary bundle IDs in: every entry point
/// here corresponds 1:1 to a fixed `SystemActionCapability`.
enum SystemActionExecutor {
    private static let vsCodeBundleID = "com.microsoft.VSCode"
    private static let xcodeBundleID = "com.apple.dt.Xcode"

    static func clickXcodeBuildButton() -> JarvisBridge.ActionResult {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == xcodeBundleID }) else {
            return .init(succeeded: false, message: "Xcode n'est pas lance.")
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let button = firstDescendant(of: axApp, matching: { element in
            role(of: element) == kAXButtonRole as String && (title(of: element)?.localizedCaseInsensitiveContains("build") ?? false)
        }) else {
            return .init(succeeded: false, message: "Bouton Build introuvable dans la fenetre Xcode au premier plan.")
        }

        app.activate()
        let status = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard status == .success else {
            return .init(succeeded: false, message: "Xcode a refuse le clic sur Build (AXError \(status.rawValue)).")
        }
        return .init(succeeded: true, message: "Clic sur Build envoye a Xcode.")
    }

    static func focusEditorWindow(project: JarvisProject) -> JarvisBridge.ActionResult {
        guard let (app, name) = runningEditor(for: project) else {
            return .init(succeeded: false, message: "Ni VS Code ni Xcode ne sont lances pour \(project.name).")
        }
        let activated = app.activate()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard activated else {
            return .init(succeeded: false, message: "\(name) n'a pas pu etre mis au premier plan.")
        }
        return .init(succeeded: true, message: "\(name) est au premier plan.")
    }

    static func typeIntoFocusedEditorField(text: String, project: JarvisProject) -> JarvisBridge.ActionResult {
        guard !text.isEmpty else {
            return .init(succeeded: false, message: "Rien a taper.")
        }
        guard let (app, name) = runningEditor(for: project), app.isActive else {
            return .init(succeeded: false, message: "VS Code ou Xcode doit deja etre au premier plan avant de taper.")
        }
        guard postUnicodeString(text) else {
            return .init(succeeded: false, message: "Impossible d'envoyer la frappe clavier a \(name).")
        }
        return .init(succeeded: true, message: "Texte envoye a \(name).")
    }

    // MARK: - Shared helpers

    private static func runningEditor(for project: JarvisProject) -> (NSRunningApplication, String)? {
        let running = NSWorkspace.shared.runningApplications
        if let vsCode = running.first(where: { $0.bundleIdentifier == vsCodeBundleID }) {
            return (vsCode, "VS Code")
        }
        if let xcode = running.first(where: { $0.bundleIdentifier == xcodeBundleID }) {
            return (xcode, "Xcode")
        }
        return nil
    }

    private static func postUnicodeString(_ text: String) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return false
        }
        let utf16 = Array(text.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    /// Bounded breadth-first search of the AX tree; capped so a pathological
    /// window (or an AX bug returning cyclic children) can't hang the app.
    private static func firstDescendant(of root: AXUIElement, matching predicate: (AXUIElement) -> Bool, maxVisited: Int = 4000) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < maxVisited {
            let element = queue.removeFirst()
            visited += 1
            if predicate(element) { return element }
            queue.append(contentsOf: children(of: element))
        }
        return nil
    }
}
