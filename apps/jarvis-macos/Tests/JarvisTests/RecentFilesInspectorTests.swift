import XCTest
@testable import Jarvis

final class RecentFilesInspectorTests: XCTestCase {
    func testSkipsIgnoredDirectoriesAndSortsByRecency() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }

        let nodeModules = root.appendingPathComponent("node_modules")
        try fm.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try "noise".write(to: nodeModules.appendingPathComponent("noise.js"), atomically: true, encoding: .utf8)

        let older = root.appendingPathComponent("older.swift")
        try "old".write(to: older, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)

        let newer = root.appendingPathComponent("newer.swift")
        try "new".write(to: newer, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: newer.path)

        let results = RecentFilesInspector.recentFiles(in: root.path)

        XCTAssertFalse(results.contains { $0.name == "noise.js" })
        XCTAssertEqual(results.first?.name, "newer.swift")
        XCTAssertEqual(results.count, 2)
    }

    func testEmptyDirectoryReturnsNoFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        XCTAssertTrue(RecentFilesInspector.recentFiles(in: root.path).isEmpty)
    }
}
