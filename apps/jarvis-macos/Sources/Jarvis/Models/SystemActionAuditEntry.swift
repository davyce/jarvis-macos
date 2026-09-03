import Foundation

/// One row of the persistent audit trail for system actions: what was run,
/// against which named target, when, and with what outcome. Never records
/// keystroke or click content, only the fixed capability + target + result.
struct SystemActionAuditEntry: Identifiable, Equatable {
    enum Outcome: String {
        case success
        case failure
        case declined
    }

    let id: UUID
    let capability: SystemActionCapability
    let target: String
    let outcome: Outcome
    let detail: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        capability: SystemActionCapability,
        target: String,
        outcome: Outcome,
        detail: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.capability = capability
        self.target = target
        self.outcome = outcome
        self.detail = detail
        self.createdAt = createdAt
    }
}
