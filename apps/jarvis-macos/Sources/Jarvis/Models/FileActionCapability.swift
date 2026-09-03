import Foundation

/// A file operation that modifies or destroys something on disk. Search,
/// directory listing, and reading text content are deliberately NOT
/// capabilities here -- they stay always-on, no toggle, no confirmation,
/// same as this app already treats any other read-only inspection.
enum FileActionCapability: String, CaseIterable, Identifiable, Codable {
    case writeFile
    case duplicateFile
    case deleteFile
    case moveFile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .writeFile: return "Modifier un fichier"
        case .duplicateFile: return "Dupliquer un fichier"
        case .deleteFile: return "Supprimer un fichier"
        case .moveFile: return "Deplacer / renommer un fichier"
        }
    }

    var summary: String {
        switch self {
        case .writeFile:
            return "Ecrit ou remplace le contenu texte d'un fichier existant, n'importe ou sur le Mac."
        case .duplicateFile:
            return "Cree une copie d'un fichier a cote de l'original."
        case .deleteFile:
            return "Envoie un fichier a la Corbeille macOS (recuperable, jamais une suppression definitive immediate)."
        case .moveFile:
            return "Deplace ou renomme un fichier existant."
        }
    }
}
