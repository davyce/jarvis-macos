import AppKit
import Foundation

enum JarvisBridge {
    enum Action {
        case openInFinder
        case openInEditor
        case createBranch(name: String)
        case addNote(text: String)
        /// Real system-automation actions (click, keystroke, window focus).
        /// Separate chantier from the four actions above: gated by
        /// Accessibility trust, a per-capability enable switch, a one-time
        /// user confirmation, and a persistent audit log. See
        /// `SystemActionCapability` and `README.md` > "Actions systeme".
        case system(SystemAction)
    }

    enum SystemAction {
        case clickXcodeBuildButton
        case focusEditorWindow
        case typeIntoFocusedEditorField(text: String)

        var capability: SystemActionCapability {
            switch self {
            case .clickXcodeBuildButton: return .clickXcodeBuildButton
            case .focusEditorWindow: return .focusEditorWindow
            case .typeIntoFocusedEditorField: return .typeIntoFocusedEditorField
            }
        }
    }

    struct ActionResult {
        let succeeded: Bool
        let message: String
    }

    static func perform(_ action: Action, on project: JarvisProject) -> ActionResult {
        switch action {
        case .openInFinder:
            return openInFinder(project)
        case .openInEditor:
            return openInEditor(project)
        case .createBranch(let name):
            return createBranch(name: name, in: project)
        case .addNote(let text):
            return addNote(text: text, in: project)
        case .system(let systemAction):
            return performSystemAction(systemAction, on: project)
        }
    }

    // MARK: - System actions

    /// Injection points so tests can exercise the gating logic (disabled
    /// capability, missing Accessibility trust, declined confirmation,
    /// confirm-once-then-skip) without touching real OS permissions, AX
    /// calls, or NSAlert.
    nonisolated(unsafe) static var accessibilityGate: () -> Bool = { AccessibilityPermission.requestIfNeeded() }
    nonisolated(unsafe) static var permissionStore: SystemActionPermissionStore = .shared
    nonisolated(unsafe) static var confirmationHandler: (SystemActionCapability) -> Bool = SystemActionConfirmation.confirm
    nonisolated(unsafe) static var auditRecorder: (SystemActionAuditEntry) -> Void = { LocalDatabase.shared.insertSystemActionAudit($0) }
    nonisolated(unsafe) static var executeSystemAction: (SystemAction, JarvisProject) -> ActionResult = { action, project in
        switch action {
        case .clickXcodeBuildButton:
            return SystemActionExecutor.clickXcodeBuildButton()
        case .focusEditorWindow:
            return SystemActionExecutor.focusEditorWindow(project: project)
        case .typeIntoFocusedEditorField(let text):
            return SystemActionExecutor.typeIntoFocusedEditorField(text: text, project: project)
        }
    }

    private static func performSystemAction(_ systemAction: SystemAction, on project: JarvisProject) -> ActionResult {
        let capability = systemAction.capability

        guard permissionStore.isEnabled(capability) else {
            return ActionResult(
                succeeded: false,
                message: "L'action \u{201C}\(capability.title)\u{201D} est desactivee. Active-la dans Connections > Actions systeme."
            )
        }

        guard accessibilityGate() else {
            return ActionResult(
                succeeded: false,
                message: "Jarvis a besoin de la permission Accessibilite macOS. Ouvre Reglages Systeme > Confidentialite et securite > Accessibilite et active Jarvis."
            )
        }

        if !permissionStore.hasConfirmed(capability) {
            guard confirmationHandler(capability) else {
                recordAudit(capability: capability, outcome: .declined, detail: "Confirmation refusee par l'utilisateur.")
                return ActionResult(succeeded: false, message: "Action annulee : confirmation refusee pour \u{201C}\(capability.title)\u{201D}.")
            }
            permissionStore.markConfirmed(capability)
        }

        let result = executeSystemAction(systemAction, project)
        recordAudit(capability: capability, outcome: result.succeeded ? .success : .failure, detail: result.message)
        return result
    }

    private static func recordAudit(capability: SystemActionCapability, outcome: SystemActionAuditEntry.Outcome, detail: String) {
        auditRecorder(SystemActionAuditEntry(capability: capability, target: capability.targetDescription, outcome: outcome, detail: detail))
    }

    private static func openInFinder(_ project: JarvisProject) -> ActionResult {
        guard FileManager.default.fileExists(atPath: project.rootPath) else {
            return ActionResult(succeeded: false, message: "Le dossier de \(project.name) est introuvable.")
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.rootPath)])
        return ActionResult(succeeded: true, message: "\(project.name) ouvert dans le Finder.")
    }

    private static func openInEditor(_ project: JarvisProject) -> ActionResult {
        guard FileManager.default.fileExists(atPath: project.rootPath) else {
            return ActionResult(succeeded: false, message: "Le dossier de \(project.name) est introuvable.")
        }
        let url = URL(fileURLWithPath: project.rootPath)

        if let vsCode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            NSWorkspace.shared.open([url], withApplicationAt: vsCode, configuration: .init(), completionHandler: nil)
            return ActionResult(succeeded: true, message: "\(project.name) ouvert dans VS Code.")
        }
        if let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode"),
           let projectFile = firstXcodeProjectFile(in: project.rootPath) {
            NSWorkspace.shared.open([projectFile], withApplicationAt: xcode, configuration: .init(), completionHandler: nil)
            return ActionResult(succeeded: true, message: "\(project.name) ouvert dans Xcode.")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return ActionResult(succeeded: false, message: "Aucun editeur reconnu (VS Code, Xcode) ; \(project.name) ouvert dans le Finder a la place.")
    }

    private static func firstXcodeProjectFile(in path: String) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return URL(fileURLWithPath: path + "/" + workspace)
        }
        if let project = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return URL(fileURLWithPath: path + "/" + project)
        }
        return nil
    }

    private static func createBranch(name: String, in project: JarvisProject) -> ActionResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ActionResult(succeeded: false, message: "Precise le nom de la branche.")
        }
        guard FileManager.default.fileExists(atPath: project.rootPath) else {
            return ActionResult(succeeded: false, message: "Le dossier de \(project.name) est introuvable.")
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", project.rootPath, "checkout", "-b", trimmed]
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            return ActionResult(succeeded: false, message: "Impossible de lancer git : \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus == 0 {
            return ActionResult(succeeded: true, message: "Branche `\(trimmed)` creee et activee sur \(project.name).")
        }
        return ActionResult(succeeded: false, message: text.isEmpty ? "Git a refuse de creer la branche." : text)
    }

    private static func addNote(text: String, in project: JarvisProject) -> ActionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ActionResult(succeeded: false, message: "Il n'y a rien a noter.")
        }
        guard FileManager.default.fileExists(atPath: project.rootPath) else {
            return ActionResult(succeeded: false, message: "Le dossier de \(project.name) est introuvable.")
        }

        let notesURL = URL(fileURLWithPath: project.rootPath).appendingPathComponent("NOTES.md")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let line = "- [\(formatter.string(from: .now))] \(trimmed)\n"

        do {
            if FileManager.default.fileExists(atPath: notesURL.path) {
                let handle = try FileHandle(forWritingTo: notesURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
            } else {
                let header = "# Notes \(project.name)\n\n"
                try (header + line).write(to: notesURL, atomically: true, encoding: .utf8)
            }
        } catch {
            return ActionResult(succeeded: false, message: "Impossible d'ecrire dans NOTES.md : \(error.localizedDescription)")
        }

        return ActionResult(succeeded: true, message: "Note ajoutee a NOTES.md (\(project.name)) : \u{201C}\(trimmed)\u{201D}")
    }
}
