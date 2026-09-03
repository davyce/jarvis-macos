import Foundation

/// Merges the two audit tables (AXUIElement system actions, LIMULE Bridge
/// calls) into one Suivi timeline. From the user's perspective it's a
/// single question -- "what has Jarvis done on my machine" -- even though
/// the two underlying systems have different auth, different scope, and
/// different schemas (a fixed capability catalog vs. an open-ended route).
enum AuditTrailEntry: Identifiable {
    case systemAction(SystemActionAuditEntry)
    case limuleBridge(LimuleBridgeAuditEntry)
    case fileAction(FileActionAuditEntry)

    var id: UUID {
        switch self {
        case .systemAction(let entry): return entry.id
        case .limuleBridge(let entry): return entry.id
        case .fileAction(let entry): return entry.id
        }
    }

    var createdAt: Date {
        switch self {
        case .systemAction(let entry): return entry.createdAt
        case .limuleBridge(let entry): return entry.createdAt
        case .fileAction(let entry): return entry.createdAt
        }
    }

    var title: String {
        switch self {
        case .systemAction(let entry): return entry.capability.title
        case .limuleBridge(let entry): return entry.summary
        case .fileAction(let entry): return entry.title
        }
    }

    var detail: String {
        switch self {
        case .systemAction(let entry): return entry.detail
        case .limuleBridge(let entry): return entry.detail
        case .fileAction(let entry): return entry.detail
        }
    }

    var origin: String {
        switch self {
        case .systemAction: return "AX"
        case .limuleBridge: return "Bridge"
        case .fileAction: return "Fichiers"
        }
    }

    var succeeded: Bool {
        switch self {
        case .systemAction(let entry): return entry.outcome == .success
        case .limuleBridge(let entry): return entry.outcome == .success
        case .fileAction(let entry): return entry.outcome == .success
        }
    }

    var wasDeclined: Bool {
        switch self {
        case .systemAction(let entry): return entry.outcome == .declined
        case .fileAction(let entry): return entry.outcome == .declined
        case .limuleBridge: return false
        }
    }

    /// All three logs, most recent first, interleaved by timestamp.
    static func loadAll(limit: Int = 30) -> [AuditTrailEntry] {
        let systemActions = LocalDatabase.shared.loadSystemActionAudit(limit: limit).map(AuditTrailEntry.systemAction)
        let bridgeCalls = LocalDatabase.shared.loadLimuleBridgeAudit(limit: limit).map(AuditTrailEntry.limuleBridge)
        let fileActions = LocalDatabase.shared.loadFileActionAudit(limit: limit).map(AuditTrailEntry.fileAction)
        return (systemActions + bridgeCalls + fileActions)
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    /// A compact factual digest injected into the assistant context. It is
    /// derived from the same persistent audit visible in Connexions, so
    /// Jarvis learns from actual tool outcomes rather than imagined ones.
    static func recentFailuresDigest(limit: Int = 6) -> String? {
        let failures = loadAll(limit: 120)
            .filter { !$0.succeeded && !$0.wasDeclined }
            .prefix(limit)
        guard !failures.isEmpty else { return nil }
        return failures.map { "- [\($0.origin)] \($0.title) : \($0.detail)" }.joined(separator: "\n")
    }
}
