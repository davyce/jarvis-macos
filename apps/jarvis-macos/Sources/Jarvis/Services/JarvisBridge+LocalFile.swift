import AppKit
import Foundation

/// Bridges `JarvisBridge` to `LocalFileService`. Kept in its own file, same
/// additive shape as `JarvisBridge+LimuleBridge.swift`: search/list/read
/// are always free (no toggle, no confirmation); write/duplicate/delete/
/// move go through the same enable-then-confirm-once gate the AXUIElement
/// system actions already use, via `FileActionPermissionStore`/
/// `FileActionConfirmation` instead of `SystemActionPermissionStore`/
/// `SystemActionConfirmation`. Every one of the seven kinds is recorded to
/// the Suivi, including the free ones -- transparency for a capability
/// whose read scope is "anywhere on the Mac".
extension JarvisBridge {
    enum FileAction {
        case search(query: String, roots: [URL]? = nil, limit: Int = 30)
        case list(path: String)
        case readText(path: String)
        case open(path: String)
        case write(path: String, content: String)
        case duplicate(path: String)
        case delete(path: String)
        case move(from: String, to: String)
    }

    struct FileActionResult {
        let succeeded: Bool
        let message: String
        let entries: [LocalFileService.FileEntry]?
        let content: String?
        var truncated: Bool = false
    }

    /// Injection points, same style as the AXUIElement system actions.
    nonisolated(unsafe) static var filePermissionStore: FileActionPermissionStore = .shared
    nonisolated(unsafe) static var fileConfirmationHandler: (FileActionCapability, String) -> Bool = FileActionConfirmation.confirm
    nonisolated(unsafe) static var fileAuditRecorder: (FileActionAuditEntry) -> Void = { LocalDatabase.shared.insertFileActionAudit($0) }

    static func performFileAction(_ action: FileAction) async -> FileActionResult {
        switch action {
        case .search(let query, let roots, let limit):
            let (entries, truncated) = await LocalFileService.search(
                query: query,
                roots: roots ?? LocalFileService.defaultSearchRoots(),
                limit: limit
            )
            let detail = truncated ? "\(entries.count) resultat(s) (liste tronquee)" : "\(entries.count) resultat(s)"
            recordFileAudit(kind: .search, target: query, outcome: .success, detail: detail)
            return FileActionResult(succeeded: true, message: detail, entries: entries, content: nil, truncated: truncated)

        case .list(let path):
            let entries = LocalFileService.listDirectory(path)
            recordFileAudit(kind: .list, target: path, outcome: .success, detail: "\(entries.count) element(s)")
            return FileActionResult(succeeded: true, message: "\(entries.count) element(s) dans \(path)", entries: entries, content: nil)

        case .readText(let path):
            do {
                let content = try LocalFileService.readTextFile(path)
                recordFileAudit(kind: .read, target: path, outcome: .success, detail: "Lu (\(content.count) caracteres)")
                return FileActionResult(succeeded: true, message: "Fichier lu : \(path)", entries: nil, content: content)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                recordFileAudit(kind: .read, target: path, outcome: .failure, detail: message)
                return FileActionResult(succeeded: false, message: message, entries: nil, content: nil)
            }

        case .open(let path):
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                let message = "Fichier introuvable : \(path)"
                recordFileAudit(kind: .open, target: path, outcome: .failure, detail: message)
                return FileActionResult(succeeded: false, message: message, entries: nil, content: nil)
            }
            NSWorkspace.shared.open(url)
            let message = "Ouvert : \(path)"
            recordFileAudit(kind: .open, target: path, outcome: .success, detail: message)
            return FileActionResult(succeeded: true, message: message, entries: nil, content: nil)

        case .write(let path, let content):
            return gated(.writeFile, target: path, kind: .write) {
                try LocalFileService.writeTextFile(path: path, content: content)
                return "Fichier ecrit : \(path)"
            }

        case .duplicate(let path):
            return gated(.duplicateFile, target: path, kind: .duplicate) {
                let newPath = try LocalFileService.duplicateFile(path: path)
                return "Copie creee : \(newPath)"
            }

        case .delete(let path):
            return gated(.deleteFile, target: path, kind: .delete) {
                try LocalFileService.deleteFile(path: path)
                return "Envoye a la Corbeille : \(path)"
            }

        case .move(let from, let to):
            return gated(.moveFile, target: "\(from) -> \(to)", kind: .move) {
                try LocalFileService.moveFile(from: from, to: to)
                return "Deplace vers \(to)"
            }
        }
    }

    private static func gated(
        _ capability: FileActionCapability,
        target: String,
        kind: FileActionAuditEntry.Kind,
        _ execute: () throws -> String
    ) -> FileActionResult {
        guard filePermissionStore.isEnabled(capability) else {
            return FileActionResult(
                succeeded: false,
                message: "L'action \u{201C}\(capability.title)\u{201D} est desactivee. Active-la dans Connections > Actions fichiers.",
                entries: nil,
                content: nil
            )
        }

        if !filePermissionStore.hasConfirmed(capability) {
            guard fileConfirmationHandler(capability, target) else {
                recordFileAudit(kind: kind, target: target, outcome: .declined, detail: "Confirmation refusee par l'utilisateur.")
                return FileActionResult(
                    succeeded: false,
                    message: "Action annulee : confirmation refusee pour \u{201C}\(capability.title)\u{201D}.",
                    entries: nil,
                    content: nil
                )
            }
            filePermissionStore.markConfirmed(capability)
        }

        do {
            let message = try execute()
            recordFileAudit(kind: kind, target: target, outcome: .success, detail: message)
            return FileActionResult(succeeded: true, message: message, entries: nil, content: nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            recordFileAudit(kind: kind, target: target, outcome: .failure, detail: message)
            return FileActionResult(succeeded: false, message: message, entries: nil, content: nil)
        }
    }

    private static func recordFileAudit(kind: FileActionAuditEntry.Kind, target: String, outcome: FileActionAuditEntry.Outcome, detail: String) {
        fileAuditRecorder(FileActionAuditEntry(kind: kind, target: target, outcome: outcome, detail: detail))
    }
}
