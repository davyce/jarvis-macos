import XCTest
@testable import Jarvis

final class FileListSpecTests: XCTestCase {
    func testParsesValidFileList() {
        let json = """
        {"query": "budget", "truncated": false,
         "entries": [{"path": "/Users/test/Documents/budget.xlsx", "isDirectory": false, "modifiedAt": 700000000}]}
        """
        guard let spec = FileListSpec.parse(from: json) else { return XCTFail("expected a parsed spec") }
        XCTAssertEqual(spec.query, "budget")
        XCTAssertFalse(spec.truncated)
        XCTAssertEqual(spec.entries.count, 1)
        XCTAssertEqual(spec.entries.first?.path, "/Users/test/Documents/budget.xlsx")
    }

    func testParsesEmptyResultList() {
        let json = """
        {"query": "nope", "truncated": false, "entries": []}
        """
        guard let spec = FileListSpec.parse(from: json) else { return XCTFail("expected a parsed spec") }
        XCTAssertTrue(spec.entries.isEmpty)
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(FileListSpec.parse(from: "{not json"))
        XCTAssertNil(FileListSpec.parse(from: ""))
    }

    func testMissingRequiredFieldReturnsNil() {
        let json = """
        {"truncated": false, "entries": []}
        """
        XCTAssertNil(FileListSpec.parse(from: json))
    }

    func testRoundTripsThroughToJSON() {
        let spec = FileListSpec(
            query: "notes",
            entries: [.init(path: "/tmp/notes.txt", isDirectory: false, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))],
            truncated: true
        )
        guard let json = spec.toJSON(), let reparsed = FileListSpec.parse(from: json) else {
            return XCTFail("expected round trip to succeed")
        }
        XCTAssertEqual(reparsed, spec)
    }
}
