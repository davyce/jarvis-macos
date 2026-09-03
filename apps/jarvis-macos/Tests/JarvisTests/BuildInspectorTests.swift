import XCTest
@testable import Jarvis

final class BuildInspectorTests: XCTestCase {
    func testDetectsNodeProject() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("package.json").path, contents: Data())

        XCTAssertEqual(BuildInspector.detectTool(projectPath: dir.path), .npm)
    }

    func testDetectsCargoProjectOverNode() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("Cargo.toml").path, contents: Data())

        XCTAssertEqual(BuildInspector.detectTool(projectPath: dir.path), .cargo)
    }

    func testDetectsNoToolForEmptyDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(BuildInspector.detectTool(projectPath: dir.path))
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
