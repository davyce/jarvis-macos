import XCTest
@testable import Jarvis

final class ScreenshotStoreTests: XCTestCase {
    /// A well-known, minimal valid 1x1 transparent PNG.
    private static let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    private var testDirectory: URL!

    override func setUp() {
        super.setUp()
        testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ScreenshotStore.directory = { [testDirectory] in testDirectory! }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDirectory)
        ScreenshotStore.directory = {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return base.appendingPathComponent("Jarvis", isDirectory: true).appendingPathComponent("Screenshots", isDirectory: true)
        }
        super.tearDown()
    }

    func testSaveWritesFileAndDecodesDimensions() throws {
        let data = Data(base64Encoded: Self.tinyPNGBase64)!

        let saved = try ScreenshotStore.save(data)

        XCTAssertEqual(saved.width, 1)
        XCTAssertEqual(saved.height, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: saved.path)), data)
    }

    func testSaveCreatesDirectoryIfMissing() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: testDirectory.path))
        let data = Data(base64Encoded: Self.tinyPNGBase64)!

        _ = try ScreenshotStore.save(data)

        XCTAssertTrue(FileManager.default.fileExists(atPath: testDirectory.path))
    }

    func testSaveWithGarbageBytesThrowsInvalidImageData() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])

        XCTAssertThrowsError(try ScreenshotStore.save(garbage)) { error in
            guard case .invalidImageData = error as? ScreenshotStore.StoreError else {
                return XCTFail("expected .invalidImageData, got \(error)")
            }
        }
    }
}
