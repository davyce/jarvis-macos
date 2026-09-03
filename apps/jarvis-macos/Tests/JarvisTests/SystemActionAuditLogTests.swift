import XCTest
@testable import Jarvis

final class SystemActionAuditLogTests: XCTestCase {
    private func makeDatabase() -> LocalDatabase {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return LocalDatabase(path: dir.appendingPathComponent("test.sqlite3"))
    }

    func testInsertAndLoadRoundTrip() {
        let db = makeDatabase()
        let entry = SystemActionAuditEntry(
            capability: .clickXcodeBuildButton,
            target: "Bouton Build - Xcode",
            outcome: .success,
            detail: "Clic envoye a Xcode."
        )
        db.insertSystemActionAudit(entry)

        let loaded = db.loadSystemActionAudit()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.capability, .clickXcodeBuildButton)
        XCTAssertEqual(loaded.first?.target, "Bouton Build - Xcode")
        XCTAssertEqual(loaded.first?.outcome, .success)
        XCTAssertEqual(loaded.first?.detail, "Clic envoye a Xcode.")
    }

    func testLoadOrdersMostRecentFirst() {
        let db = makeDatabase()
        db.insertSystemActionAudit(SystemActionAuditEntry(
            capability: .focusEditorWindow, target: "t", outcome: .success, detail: "first",
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        db.insertSystemActionAudit(SystemActionAuditEntry(
            capability: .focusEditorWindow, target: "t", outcome: .success, detail: "second",
            createdAt: Date(timeIntervalSince1970: 2)
        ))

        let loaded = db.loadSystemActionAudit()
        XCTAssertEqual(loaded.map(\.detail), ["second", "first"])
    }

    func testRecordsEveryOutcomeKind() {
        let db = makeDatabase()
        db.insertSystemActionAudit(SystemActionAuditEntry(capability: .clickXcodeBuildButton, target: "t", outcome: .success, detail: "ok"))
        db.insertSystemActionAudit(SystemActionAuditEntry(capability: .clickXcodeBuildButton, target: "t", outcome: .failure, detail: "ko"))
        db.insertSystemActionAudit(SystemActionAuditEntry(capability: .clickXcodeBuildButton, target: "t", outcome: .declined, detail: "no"))

        let loaded = db.loadSystemActionAudit()
        XCTAssertEqual(Set(loaded.map(\.outcome)), [.success, .failure, .declined])
    }
}
