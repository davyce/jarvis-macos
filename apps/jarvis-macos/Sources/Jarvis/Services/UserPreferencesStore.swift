import Foundation

/// Free-text notes about how Davy wants Jarvis to work with him -- style,
/// standing decisions, things not to repeat -- persisted so every new
/// conversation doesn't start from zero. Deliberately not an automatic
/// extraction pipeline (the model deciding turn-by-turn what counts as a
/// "preference" worth remembering is a much bigger, fuzzier feature): Davy
/// edits this directly in Connexions, and it's included verbatim in the
/// system prompt whenever it isn't empty.
enum UserPreferencesStore {
    private static let notesKey = "jarvis.userPreferences.notes.v1"

    static var notes: String {
        UserDefaults.standard.string(forKey: notesKey) ?? ""
    }

    static func setNotes(_ notes: String) {
        UserDefaults.standard.set(notes, forKey: notesKey)
    }
}
