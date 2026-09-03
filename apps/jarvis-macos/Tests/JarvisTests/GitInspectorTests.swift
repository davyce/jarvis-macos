import XCTest
@testable import Jarvis

final class GitInspectorTests: XCTestCase {
    func testUnavailablePathReturnsUnavailableSnapshot() {
        let snapshot = GitInspector.inspect(projectPath: "/tmp/jarvis-project-that-does-not-exist")

        XCTAssertFalse(snapshot.isRepository)
        XCTAssertEqual(snapshot.branch, "Unavailable")
        XCTAssertEqual(snapshot.changedFileCount, 0)
    }
}
