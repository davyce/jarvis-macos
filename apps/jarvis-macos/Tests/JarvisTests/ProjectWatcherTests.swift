import XCTest
@testable import Jarvis

final class ProjectWatcherTests: XCTestCase {
    func testDetectsFileChangeInWatchedDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let expectation = expectation(description: "change detected")
        let watcher = ProjectWatcher(path: root.path) {
            expectation.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }

        // Give FSEvents a moment to register the stream before writing.
        Thread.sleep(forTimeInterval: 0.3)
        try "hello".write(to: root.appendingPathComponent("new-file.txt"), atomically: true, encoding: .utf8)

        wait(for: [expectation], timeout: 5)
    }
}
