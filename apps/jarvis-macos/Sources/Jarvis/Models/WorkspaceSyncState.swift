import Foundation

/// Status of the Limule cloud state sync (conversations + projects), shown
/// in Connections. Sync is always best-effort and additive to local
/// storage -- Jarvis must keep working fully offline regardless of this
/// state, so nothing here ever blocks or throws into the UI layer.
enum WorkspaceSyncState: Equatable {
    case idle
    case syncing
    case synced(at: Date)
    case unavailable(reason: String)

    var statusLabel: String {
        switch self {
        case .idle: return "Pas encore synchronise"
        case .syncing: return "Synchronisation..."
        case .synced: return "Synchronise"
        case .unavailable(let reason): return reason
        }
    }

    var isHealthy: Bool {
        if case .synced = self { return true }
        return false
    }
}
