import XCTest
@testable import Jarvis

final class WorkspacePreviewComposerTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testShortFilePreviewReturnsFullContent() throws {
        let fileURL = tempDir.appendingPathComponent("short.txt")
        try "Hello, Jarvis.".write(to: fileURL, atomically: true, encoding: .utf8)

        let item = WorkspaceItem(id: "1", path: fileURL.path, kind: .file, addedAt: .now)
        XCTAssertEqual(WorkspacePreviewComposer.preview(for: item), "Hello, Jarvis.")
    }

    func testLongFilePreviewIsTruncatedWithEllipsis() throws {
        let fileURL = tempDir.appendingPathComponent("long.txt")
        let longText = String(repeating: "a", count: 1_000)
        try longText.write(to: fileURL, atomically: true, encoding: .utf8)

        let item = WorkspaceItem(id: "1", path: fileURL.path, kind: .file, addedAt: .now)
        let preview = WorkspacePreviewComposer.preview(for: item)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertLessThan(preview.count, longText.count)
    }

    func testMissingFileReturnsUnavailableMarker() {
        let item = WorkspaceItem(id: "1", path: tempDir.appendingPathComponent("nope.txt").path, kind: .file, addedAt: .now)
        XCTAssertTrue(WorkspacePreviewComposer.preview(for: item).contains("indisponible"))
    }

    func testFolderPreviewListsVisibleEntriesSortedAndHidesDotfiles() throws {
        try "a".write(to: tempDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "a".write(to: tempDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "a".write(to: tempDir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        let item = WorkspaceItem(id: "1", path: tempDir.path, kind: .folder, addedAt: .now)
        let preview = WorkspacePreviewComposer.preview(for: item)
        XCTAssertEqual(preview, "a.txt, b.txt")
    }

    func testEmptyFolderIsMarked() throws {
        let item = WorkspaceItem(id: "1", path: tempDir.path, kind: .folder, addedAt: .now)
        XCTAssertEqual(WorkspacePreviewComposer.preview(for: item), "(dossier vide)")
    }

    func testMissingFolderReturnsUnreadableMarker() {
        let item = WorkspaceItem(id: "1", path: tempDir.appendingPathComponent("nope").path, kind: .folder, addedAt: .now)
        XCTAssertTrue(WorkspacePreviewComposer.preview(for: item).contains("illisible"))
    }
}
