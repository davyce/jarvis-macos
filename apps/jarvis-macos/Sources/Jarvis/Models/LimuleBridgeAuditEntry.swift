import Foundation

/// One row of the persistent Suivi entry for a LIMULE Bridge call. Unlike
/// `SystemActionAuditEntry` (a fixed capability catalog), Bridge actions are
/// open-ended, so this keys on the route path and an HTTP status rather than
/// a closed enum -- the redacted `summary` is `LimuleBridgeAction.auditSummary`,
/// never raw call parameters.
struct LimuleBridgeAuditEntry: Identifiable, Equatable {
    enum Outcome: String {
        case success
        case failure
    }

    let id: UUID
    let route: String
    let summary: String
    let outcome: Outcome
    let httpStatus: Int?
    let detail: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        route: String,
        summary: String,
        outcome: Outcome,
        httpStatus: Int? = nil,
        detail: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.route = route
        self.summary = summary
        self.outcome = outcome
        self.httpStatus = httpStatus
        self.detail = detail
        self.createdAt = createdAt
    }
}
