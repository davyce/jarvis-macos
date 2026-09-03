import XCTest
@testable import Jarvis

final class LocalDatabaseTests: XCTestCase {
    func testInsertAndLoadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = LocalDatabase(path: dir.appendingPathComponent("test.sqlite3"))

        let entry = CommandEntry(role: .user, text: "Hello", detail: "detail")
        db.insert(entry, conversationID: "convo-1")

        let loaded = db.loadHistory(conversationID: "convo-1")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.text, "Hello")
        XCTAssertEqual(loaded.first?.role, .user)
        XCTAssertEqual(loaded.first?.detail, "detail")
    }

    func testPreservesInsertionOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = LocalDatabase(path: dir.appendingPathComponent("test.sqlite3"))

        db.insert(CommandEntry(role: .user, text: "first", detail: nil, createdAt: Date(timeIntervalSince1970: 1)), conversationID: "convo-1")
        db.insert(CommandEntry(role: .jarvis, text: "second", detail: nil, createdAt: Date(timeIntervalSince1970: 2)), conversationID: "convo-1")

        let loaded = db.loadHistory(conversationID: "convo-1")
        XCTAssertEqual(loaded.map(\.text), ["first", "second"])
    }

    func testHistoryIsScopedToConversation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = LocalDatabase(path: dir.appendingPathComponent("test.sqlite3"))

        db.insert(CommandEntry(role: .user, text: "in convo 1", detail: nil), conversationID: "convo-1")
        db.insert(CommandEntry(role: .user, text: "in convo 2", detail: nil), conversationID: "convo-2")

        XCTAssertEqual(db.loadHistory(conversationID: "convo-1").map(\.text), ["in convo 1"])
        XCTAssertEqual(db.loadHistory(conversationID: "convo-2").map(\.text), ["in convo 2"])
    }

    func testConversationsRoundTripAndRename() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = LocalDatabase(path: dir.appendingPathComponent("test.sqlite3"))

        let conversation = Conversation.started(at: Date(timeIntervalSince1970: 10))
        db.createConversation(conversation)
        db.renameConversation(conversation.id, title: "Premiere question")

        let loaded = db.loadConversations()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Premiere question")
    }

    func testUpsertConversationInsertsThenUpdates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = LocalDatabase(path: dir.appendingPathComponent("test.sqlite3"))

        let conversation = Conversation(id: "c1", title: "First", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        db.upsertConversation(conversation)
        XCTAssertEqual(db.loadConversations().first?.title, "First")

        let updated = Conversation(id: "c1", title: "Renamed", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
        db.upsertConversation(updated)

        let loaded = db.loadConversations()
        XCTAssertEqual(loaded.count, 1, "must update in place, not duplicate")
        XCTAssertEqual(loaded.first?.title, "Renamed")
    }

    func testInsertMessageIfMissingDoesNotDuplicate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = LocalDatabase(path: dir.appendingPathComponent("test.sqlite3"))

        let entry = CommandEntry(role: .user, text: "hello", detail: nil)
        db.insert(entry, conversationID: "convo-1")
        db.insertMessageIfMissing(entry, conversationID: "convo-1")

        XCTAssertEqual(db.loadHistory(conversationID: "convo-1").count, 1, "same id must not be duplicated")
    }

    func testInsertMessageIfMissingAddsNewMessage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = LocalDatabase(path: dir.appendingPathComponent("test.sqlite3"))

        db.insertMessageIfMissing(CommandEntry(role: .user, text: "from another device", detail: nil), conversationID: "convo-1")

        XCTAssertEqual(db.loadHistory(conversationID: "convo-1").map(\.text), ["from another device"])
    }

    func testLimuleBridgeAuditRoundTripAndOrdering() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = LocalDatabase(path: dir.appendingPathComponent("test.sqlite3"))

        db.insertLimuleBridgeAudit(LimuleBridgeAuditEntry(
            route: "/click", summary: "Clic en (1, 2)", outcome: .success, httpStatus: 200, detail: "ok",
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        db.insertLimuleBridgeAudit(LimuleBridgeAuditEntry(
            route: "/press", summary: "Clic sur X", outcome: .failure, httpStatus: nil, detail: "No such window",
            createdAt: Date(timeIntervalSince1970: 2)
        ))

        let loaded = db.loadLimuleBridgeAudit()
        XCTAssertEqual(loaded.map(\.route), ["/press", "/click"], "most recent first")
        XCTAssertEqual(loaded.first?.outcome, .failure)
        XCTAssertEqual(loaded.first?.httpStatus, nil)
        XCTAssertEqual(loaded.last?.httpStatus, 200)
    }

    func testClearHistoryRemovesEntries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = LocalDatabase(path: dir.appendingPathComponent("test.sqlite3"))

        db.insert(CommandEntry(role: .user, text: "hello", detail: nil), conversationID: "convo-1")
        db.clearHistory()

        XCTAssertTrue(db.loadHistory(conversationID: "convo-1").isEmpty)
    }
}
