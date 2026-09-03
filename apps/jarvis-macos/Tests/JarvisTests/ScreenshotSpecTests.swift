import XCTest
@testable import Jarvis

final class ScreenshotSpecTests: XCTestCase {
    func testParsesValidScreenshot() {
        let json = """
        {"path": "/tmp/shot.png", "width": 1920, "height": 1080, "capturedAt": 700000000, "displayID": 1}
        """
        guard let spec = ScreenshotSpec.parse(from: json) else { return XCTFail("expected a parsed spec") }
        XCTAssertEqual(spec.path, "/tmp/shot.png")
        XCTAssertEqual(spec.width, 1920)
        XCTAssertEqual(spec.height, 1080)
        XCTAssertEqual(spec.displayID, 1)
    }

    func testParsesWithoutDisplayID() {
        let json = """
        {"path": "/tmp/shot.png", "width": 800, "height": 600, "capturedAt": 700000000, "displayID": null}
        """
        guard let spec = ScreenshotSpec.parse(from: json) else { return XCTFail("expected a parsed spec") }
        XCTAssertNil(spec.displayID)
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(ScreenshotSpec.parse(from: "{not json"))
        XCTAssertNil(ScreenshotSpec.parse(from: ""))
    }

    func testMissingRequiredFieldReturnsNil() {
        let json = """
        {"width": 800, "height": 600, "capturedAt": 700000000}
        """
        XCTAssertNil(ScreenshotSpec.parse(from: json))
    }

    func testRoundTripsThroughToJSON() {
        let spec = ScreenshotSpec(path: "/tmp/shot.png", width: 1024, height: 768, capturedAt: Date(timeIntervalSince1970: 1_700_000_000), displayID: 2)
        guard let json = spec.toJSON(), let reparsed = ScreenshotSpec.parse(from: json) else {
            return XCTFail("expected round trip to succeed")
        }
        XCTAssertEqual(reparsed, spec)
    }
}
