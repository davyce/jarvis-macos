import Foundation

/// One row of the persistent audit trail for file actions: what kind of
/// action, against which path (or "from -> to" for a move), when, and with
/// what outcome. Covers all seven kinds (including the three free,
/// unconfirmed read-only ones) so a search/read across "anywhere on the
/// Mac" stays transparent after the fact, matching how `LimuleBridgeAction`
/// already audits its own reads.
struct FileActionAuditEntry: Identifiable, Equatable {
    enum Kind: String {
        case search, list, read, open, write, duplicate, delete, move
    }

    enum Outcome: String {
        case success
        case failure
        case declined
    }

    let id: UUID
    let kind: Kind
    let target: String
    let outcome: Outcome
    let detail: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        target: String,
        outcome: Outcome,
        detail: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.outcome = outcome
        self.detail = detail
        self.createdAt = createdAt
    }

    var title: String {
        switch kind {
        case .search: return "Recherche de fichiers"
        case .list: return "Liste d'un dossier"
        case .read: return "Lecture d'un fichier"
        case .open: return "Ouverture d'un fichier"
        case .write: return "Modification d'un fichier"
        case .duplicate: return "Duplication d'un fichier"
        case .delete: return "Suppression d'un fichier"
        case .move: return "Deplacement / renommage d'un fichier"
        }
    }
}
