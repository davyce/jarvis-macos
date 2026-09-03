import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local SQLite store for state that should survive an app relaunch.
/// Schema lives in `database/migrations` and `database/schemas` at the repo root.
final class LocalDatabase: @unchecked Sendable {
    static let shared = LocalDatabase(path: LocalDatabase.defaultStoreURL())

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.adansonia.jarvis.database")

    init(path: URL) {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if sqlite3_open(path.path, &db) != SQLITE_OK {
            db = nil
        }
        migrate()
    }

    static func defaultStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Jarvis", isDirectory: true).appendingPathComponent("jarvis.sqlite3")
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS command_history (
            id TEXT PRIMARY KEY,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            detail TEXT,
            created_at REAL NOT NULL,
            conversation_id TEXT NOT NULL DEFAULT 'legacy'
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS system_action_audit_log (
            id TEXT PRIMARY KEY,
            capability TEXT NOT NULL,
            target TEXT NOT NULL,
            outcome TEXT NOT NULL,
            detail TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS limule_bridge_audit_log (
            id TEXT PRIMARY KEY,
            route TEXT NOT NULL,
            summary TEXT NOT NULL,
            outcome TEXT NOT NULL,
            http_status INTEGER,
            detail TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS file_action_audit_log (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            target TEXT NOT NULL,
            outcome TEXT NOT NULL,
            detail TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """)
        migrateConversationIDColumnIfNeeded()
    }

    /// Databases created before conversations existed have a `command_history`
    /// table with no `conversation_id` column. Add it and fold every existing
    /// row into a single "legacy" conversation so nothing is lost.
    private func migrateConversationIDColumnIfNeeded() {
        guard let db, !columnExists(table: "command_history", column: "conversation_id") else { return }

        exec("ALTER TABLE command_history ADD COLUMN conversation_id TEXT NOT NULL DEFAULT 'legacy'")
        let now = Date().timeIntervalSince1970
        let sql = "INSERT OR IGNORE INTO conversations (id, title, created_at, updated_at) VALUES ('legacy', 'Historique', ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now)
        sqlite3_bind_double(statement, 2, now)
        sqlite3_step(statement)
    }

    private func columnExists(table: String, column: String) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(statement, 1), String(cString: namePtr) == column {
                return true
            }
        }
        return false
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func insert(_ entry: CommandEntry, conversationID: String) {
        queue.sync {
            guard let db else { return }
            let sql = "INSERT INTO command_history (id, role, text, detail, created_at, conversation_id) VALUES (?, ?, ?, ?, ?, ?)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, entry.id.uuidString, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, entry.role.rawValue, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, entry.text, -1, sqliteTransient)
            if let detail = entry.detail {
                sqlite3_bind_text(statement, 4, detail, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_bind_double(statement, 5, entry.createdAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 6, conversationID, -1, sqliteTransient)
            sqlite3_step(statement)
        }
    }

    func loadHistory(conversationID: String, limit: Int = 200) -> [CommandEntry] {
        queue.sync {
            guard let db else { return [] }
            let sql = "SELECT id, role, text, detail, created_at FROM command_history WHERE conversation_id = ? ORDER BY created_at ASC LIMIT ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, conversationID, -1, sqliteTransient)
            sqlite3_bind_int(statement, 2, Int32(limit))

            var results: [CommandEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let roleText = sqlite3_column_text(statement, 1),
                      let bodyText = sqlite3_column_text(statement, 2) else { continue }

                let id = UUID(uuidString: String(cString: idText)) ?? UUID()
                let role = CommandEntry.Role(rawValue: String(cString: roleText)) ?? .jarvis
                let text = String(cString: bodyText)
                let detail = sqlite3_column_text(statement, 3).map { String(cString: $0) }
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))

                results.append(CommandEntry(id: id, role: role, text: text, detail: detail, createdAt: createdAt))
            }
            return results
        }
    }

    func createConversation(_ conversation: Conversation) {
        queue.sync {
            guard let db else { return }
            let sql = "INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, conversation.id, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, conversation.title, -1, sqliteTransient)
            sqlite3_bind_double(statement, 3, conversation.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, conversation.updatedAt.timeIntervalSince1970)
            sqlite3_step(statement)
        }
    }

    func loadConversations() -> [Conversation] {
        queue.sync {
            guard let db else { return [] }
            let sql = "SELECT id, title, created_at, updated_at FROM conversations ORDER BY updated_at DESC"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            var results: [Conversation] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let titleText = sqlite3_column_text(statement, 1) else { continue }
                results.append(Conversation(
                    id: String(cString: idText),
                    title: String(cString: titleText),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                ))
            }
            return results
        }
    }

    func touchConversation(_ id: String, updatedAt: Date) {
        queue.sync {
            guard let db else { return }
            let sql = "UPDATE conversations SET updated_at = ? WHERE id = ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, updatedAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 2, id, -1, sqliteTransient)
            sqlite3_step(statement)
        }
    }

    func renameConversation(_ id: String, title: String) {
        queue.sync {
            guard let db else { return }
            let sql = "UPDATE conversations SET title = ? WHERE id = ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, title, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, id, -1, sqliteTransient)
            sqlite3_step(statement)
        }
    }

    /// Insert-or-replace, unlike `createConversation`'s plain insert --
    /// used when merging a conversation pulled from Limule's state sync,
    /// where the same id may already exist locally with older metadata.
    func upsertConversation(_ conversation: Conversation) {
        queue.sync {
            guard let db else { return }
            let sql = """
            INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, updated_at = excluded.updated_at
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, conversation.id, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, conversation.title, -1, sqliteTransient)
            sqlite3_bind_double(statement, 3, conversation.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 4, conversation.updatedAt.timeIntervalSince1970)
            sqlite3_step(statement)
        }
    }

    /// Insert-or-ignore by id -- used when merging messages pulled from
    /// Limule's state sync, so a message already present locally (pushed
    /// from this same device, or already merged in a prior sync) is never
    /// duplicated.
    func insertMessageIfMissing(_ entry: CommandEntry, conversationID: String) {
        queue.sync {
            guard let db else { return }
            let sql = "INSERT OR IGNORE INTO command_history (id, role, text, detail, created_at, conversation_id) VALUES (?, ?, ?, ?, ?, ?)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, entry.id.uuidString, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, entry.role.rawValue, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, entry.text, -1, sqliteTransient)
            if let detail = entry.detail {
                sqlite3_bind_text(statement, 4, detail, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_bind_double(statement, 5, entry.createdAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 6, conversationID, -1, sqliteTransient)
            sqlite3_step(statement)
        }
    }

    /// Deletes one conversation and every message in it -- permanent, no
    /// undo (unlike file deletion elsewhere in this app, which goes to the
    /// Trash; a chat conversation has no equivalent recoverable location).
    func deleteConversation(_ id: String) {
        queue.sync {
            guard let db else { return }
            for sql in ["DELETE FROM command_history WHERE conversation_id = ?", "DELETE FROM conversations WHERE id = ?"] {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }
                sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)
                sqlite3_step(statement)
                sqlite3_finalize(statement)
            }
        }
    }

    func clearHistory() {
        queue.sync {
            _ = exec("DELETE FROM command_history")
            _ = exec("DELETE FROM conversations")
        }
    }

    func insertSystemActionAudit(_ entry: SystemActionAuditEntry) {
        queue.sync {
            guard let db else { return }
            let sql = "INSERT INTO system_action_audit_log (id, capability, target, outcome, detail, created_at) VALUES (?, ?, ?, ?, ?, ?)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, entry.id.uuidString, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, entry.capability.rawValue, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, entry.target, -1, sqliteTransient)
            sqlite3_bind_text(statement, 4, entry.outcome.rawValue, -1, sqliteTransient)
            sqlite3_bind_text(statement, 5, entry.detail, -1, sqliteTransient)
            sqlite3_bind_double(statement, 6, entry.createdAt.timeIntervalSince1970)
            sqlite3_step(statement)
        }
    }

    func loadSystemActionAudit(limit: Int = 200) -> [SystemActionAuditEntry] {
        queue.sync {
            guard let db else { return [] }
            let sql = "SELECT id, capability, target, outcome, detail, created_at FROM system_action_audit_log ORDER BY created_at DESC LIMIT ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))

            var results: [SystemActionAuditEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let capabilityText = sqlite3_column_text(statement, 1),
                      let targetText = sqlite3_column_text(statement, 2),
                      let outcomeText = sqlite3_column_text(statement, 3),
                      let detailText = sqlite3_column_text(statement, 4),
                      let id = UUID(uuidString: String(cString: idText)),
                      let capability = SystemActionCapability(rawValue: String(cString: capabilityText)),
                      let outcome = SystemActionAuditEntry.Outcome(rawValue: String(cString: outcomeText)) else { continue }

                results.append(SystemActionAuditEntry(
                    id: id,
                    capability: capability,
                    target: String(cString: targetText),
                    outcome: outcome,
                    detail: String(cString: detailText),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                ))
            }
            return results
        }
    }

    func insertLimuleBridgeAudit(_ entry: LimuleBridgeAuditEntry) {
        queue.sync {
            guard let db else { return }
            let sql = "INSERT INTO limule_bridge_audit_log (id, route, summary, outcome, http_status, detail, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, entry.id.uuidString, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, entry.route, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, entry.summary, -1, sqliteTransient)
            sqlite3_bind_text(statement, 4, entry.outcome.rawValue, -1, sqliteTransient)
            if let httpStatus = entry.httpStatus {
                sqlite3_bind_int(statement, 5, Int32(httpStatus))
            } else {
                sqlite3_bind_null(statement, 5)
            }
            sqlite3_bind_text(statement, 6, entry.detail, -1, sqliteTransient)
            sqlite3_bind_double(statement, 7, entry.createdAt.timeIntervalSince1970)
            sqlite3_step(statement)
        }
    }

    func loadLimuleBridgeAudit(limit: Int = 200) -> [LimuleBridgeAuditEntry] {
        queue.sync {
            guard let db else { return [] }
            let sql = "SELECT id, route, summary, outcome, http_status, detail, created_at FROM limule_bridge_audit_log ORDER BY created_at DESC LIMIT ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))

            var results: [LimuleBridgeAuditEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let routeText = sqlite3_column_text(statement, 1),
                      let summaryText = sqlite3_column_text(statement, 2),
                      let outcomeText = sqlite3_column_text(statement, 3),
                      let detailText = sqlite3_column_text(statement, 5),
                      let id = UUID(uuidString: String(cString: idText)),
                      let outcome = LimuleBridgeAuditEntry.Outcome(rawValue: String(cString: outcomeText)) else { continue }

                let httpStatus: Int? = sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(statement, 4))

                results.append(LimuleBridgeAuditEntry(
                    id: id,
                    route: String(cString: routeText),
                    summary: String(cString: summaryText),
                    outcome: outcome,
                    httpStatus: httpStatus,
                    detail: String(cString: detailText),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
                ))
            }
            return results
        }
    }

    func insertFileActionAudit(_ entry: FileActionAuditEntry) {
        queue.sync {
            guard let db else { return }
            let sql = "INSERT INTO file_action_audit_log (id, kind, target, outcome, detail, created_at) VALUES (?, ?, ?, ?, ?, ?)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, entry.id.uuidString, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, entry.kind.rawValue, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, entry.target, -1, sqliteTransient)
            sqlite3_bind_text(statement, 4, entry.outcome.rawValue, -1, sqliteTransient)
            sqlite3_bind_text(statement, 5, entry.detail, -1, sqliteTransient)
            sqlite3_bind_double(statement, 6, entry.createdAt.timeIntervalSince1970)
            sqlite3_step(statement)
        }
    }

    func loadFileActionAudit(limit: Int = 200) -> [FileActionAuditEntry] {
        queue.sync {
            guard let db else { return [] }
            let sql = "SELECT id, kind, target, outcome, detail, created_at FROM file_action_audit_log ORDER BY created_at DESC LIMIT ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))

            var results: [FileActionAuditEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let kindText = sqlite3_column_text(statement, 1),
                      let targetText = sqlite3_column_text(statement, 2),
                      let outcomeText = sqlite3_column_text(statement, 3),
                      let detailText = sqlite3_column_text(statement, 4),
                      let id = UUID(uuidString: String(cString: idText)),
                      let kind = FileActionAuditEntry.Kind(rawValue: String(cString: kindText)),
                      let outcome = FileActionAuditEntry.Outcome(rawValue: String(cString: outcomeText)) else { continue }

                results.append(FileActionAuditEntry(
                    id: id,
                    kind: kind,
                    target: String(cString: targetText),
                    outcome: outcome,
                    detail: String(cString: detailText),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                ))
            }
            return results
        }
    }
}
