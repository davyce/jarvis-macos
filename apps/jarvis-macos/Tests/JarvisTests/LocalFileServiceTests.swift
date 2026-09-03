import XCTest
@testable import Jarvis

final class LocalFileServiceTests: XCTestCase {
    override func tearDown() {
        LocalFileService.trash = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        super.tearDown()
    }

    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Search

    func testSearchMatchesByFilenameCaseAndAccentInsensitive() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appendingPathComponent("RÉSUMÉ.txt"), atomically: true, encoding: .utf8)
        try "hello".write(to: root.appendingPathComponent("unrelated.txt"), atomically: true, encoding: .utf8)

        let (entries, truncated) = await LocalFileService.search(query: "resume", roots: [root])

        XCTAssertFalse(truncated)
        XCTAssertEqual(entries.map(\.name), ["RÉSUMÉ.txt"])
    }

    func testSearchMatchesByFileContent() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "the secret ingredient is basil".write(to: root.appendingPathComponent("recipe.txt"), atomically: true, encoding: .utf8)
        try "nothing interesting here".write(to: root.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)

        let (entries, _) = await LocalFileService.search(query: "basil", roots: [root])

        XCTAssertEqual(entries.map(\.name), ["recipe.txt"])
    }

    func testSearchSkipsIgnoredDirectories() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nodeModules = root.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try "target".write(to: nodeModules.appendingPathComponent("target.txt"), atomically: true, encoding: .utf8)

        let (entries, _) = await LocalFileService.search(query: "target", roots: [root])

        XCTAssertTrue(entries.isEmpty)
    }

    func testSearchEmptyQueryReturnsNoResults() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let (entries, truncated) = await LocalFileService.search(query: "", roots: [root])

        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(truncated)
    }

    // MARK: - Duplicate

    func testDuplicateFileIncrementsOnCollision() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("notes.txt")
        try "content".write(to: original, atomically: true, encoding: .utf8)

        let firstCopy = try LocalFileService.duplicateFile(path: original.path)
        XCTAssertEqual((firstCopy as NSString).lastPathComponent, "notes copie.txt")

        let secondCopy = try LocalFileService.duplicateFile(path: original.path)
        XCTAssertEqual((secondCopy as NSString).lastPathComponent, "notes copie 2.txt")
    }

    func testDuplicateMissingSourceThrows() {
        XCTAssertThrowsError(try LocalFileService.duplicateFile(path: "/tmp/does-not-exist-\(UUID().uuidString).txt"))
    }

    // MARK: - Move

    func testMoveMissingSourceThrows() {
        XCTAssertThrowsError(try LocalFileService.moveFile(from: "/tmp/does-not-exist-\(UUID().uuidString).txt", to: "/tmp/dest.txt"))
    }

    func testMoveToExistingDestinationThrows() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.txt")
        let destination = root.appendingPathComponent("b.txt")
        try "a".write(to: source, atomically: true, encoding: .utf8)
        try "b".write(to: destination, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try LocalFileService.moveFile(from: source.path, to: destination.path))
    }

    func testMoveRenamesSuccessfully() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("old.txt")
        let destination = root.appendingPathComponent("new.txt")
        try "content".write(to: source, atomically: true, encoding: .utf8)

        try LocalFileService.moveFile(from: source.path, to: destination.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Delete (injectable trash)

    func testDeleteMissingSourceThrowsWithoutCallingTrash() {
        var trashCalled = false
        LocalFileService.trash = { _ in trashCalled = true }

        XCTAssertThrowsError(try LocalFileService.deleteFile(path: "/tmp/does-not-exist-\(UUID().uuidString).txt"))
        XCTAssertFalse(trashCalled)
    }

    func testDeletePassesCorrectURLToTrash() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("to-delete.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        var trashedURL: URL?
        LocalFileService.trash = { url in trashedURL = url }

        try LocalFileService.deleteFile(path: file.path)

        XCTAssertEqual(trashedURL?.path, file.path)
    }

    // MARK: - Write / read round trip

    func testWriteThenReadRoundTrip() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")

        try LocalFileService.writeTextFile(path: file.path, content: "hello jarvis")

        XCTAssertEqual(try LocalFileService.readTextFile(file.path), "hello jarvis")
    }

    // MARK: - Tilde expansion

    func testWriteAndReadExpandTildeInPath() throws {
        let relative = "jarvis-tests-\(UUID().uuidString).txt"
        let expanded = (("~/" + relative) as NSString).expandingTildeInPath
        defer { try? FileManager.default.removeItem(atPath: expanded) }

        try LocalFileService.writeTextFile(path: "~/\(relative)", content: "tilde works")

        XCTAssertTrue(FileManager.default.fileExists(atPath: expanded), "write should have landed at the expanded path, not a literal '~' directory")
        XCTAssertEqual(try LocalFileService.readTextFile("~/\(relative)"), "tilde works")
    }
}
