import Foundation

/// A named, pre-scoped system-automation capability Jarvis Bridge may perform.
///
/// Each case is a fixed, hard-coded target (an app + a specific control) rather
/// than a general "click anywhere / type anything" primitive: the catalog, not
/// the caller, decides what can be clicked, typed into, or focused. Adding a
/// new capability means adding a case here, not passing new coordinates at
/// call time.
enum SystemActionCapability: String, CaseIterable, Identifiable, Codable {
    case clickXcodeBuildButton
    case focusEditorWindow
    case typeIntoFocusedEditorField

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clickXcodeBuildButton: return "Cliquer sur Build dans Xcode"
        case .focusEditorWindow: return "Mettre l'editeur au premier plan"
        case .typeIntoFocusedEditorField: return "Ecrire dans le champ actif de l'editeur"
        }
    }

    var summary: String {
        switch self {
        case .clickXcodeBuildButton:
            return "Cherche le bouton \u{201C}Build\u{201D} dans la fenetre Xcode au premier plan et clique dessus. N'agit pas si Xcode n'est pas ouvert ou si le bouton est introuvable."
        case .focusEditorWindow:
            return "Active VS Code ou Xcode (l'editeur du projet focus) et le ramene au premier plan."
        case .typeIntoFocusedEditorField:
            return "Simule une frappe clavier dans le champ actuellement focus de VS Code ou Xcode. N'agit que si l'un des deux est deja au premier plan."
        }
    }

    /// Human-readable description of exactly what this capability is scoped
    /// to touch, shown in the confirmation prompt, the settings toggle, and
    /// persisted in the audit log.
    var targetDescription: String {
        switch self {
        case .clickXcodeBuildButton: return "Bouton \u{201C}Build\u{201D} \u{2014} Xcode (com.apple.dt.Xcode)"
        case .focusEditorWindow: return "Fenetre principale \u{2014} VS Code ou Xcode"
        case .typeIntoFocusedEditorField: return "Champ focus \u{2014} VS Code ou Xcode"
        }
    }
}
