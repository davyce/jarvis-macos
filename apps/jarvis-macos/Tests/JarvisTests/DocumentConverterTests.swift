import XCTest
@testable import Jarvis

final class DocumentConverterTests: XCTestCase {
    override func tearDown() {
        DocumentConverter.runAppleScript = { source in
            var errorDict: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                throw DocumentConverter.ConversionError.automationFailed("Script invalide.")
            }
            script.executeAndReturnError(&errorDict)
            if let errorDict {
                throw DocumentConverter.ConversionError.automationFailed(errorDict[NSAppleScript.errorMessage] as? String ?? "Erreur inconnue.")
            }
        }
        super.tearDown()
    }

    // MARK: - canConvert

    func testCanConvertKnownFormats() {
        XCTAssertTrue(DocumentConverter.canConvert(extension: "pages"))
        XCTAssertTrue(DocumentConverter.canConvert(extension: "numbers"))
        XCTAssertTrue(DocumentConverter.canConvert(extension: "docx"))
        XCTAssertTrue(DocumentConverter.canConvert(extension: "RTF"), "extension check must be case-insensitive")
    }

    func testCannotConvertKeynoteOrUnknownFormats() {
        XCTAssertFalse(DocumentConverter.canConvert(extension: "key"), "Keynote export has no plain-text option")
        XCTAssertFalse(DocumentConverter.canConvert(extension: "png"))
        XCTAssertFalse(DocumentConverter.canConvert(extension: "txt"), "plain text needs no conversion at all")
    }

    // MARK: - Rich text (NSAttributedString path, no automation)

    func testExtractsTextFromRTF() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let attributed = NSAttributedString(string: "Bonjour Jarvis")
        let rtfData = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let file = root.appendingPathComponent("note.rtf")
        try rtfData.write(to: file)

        let text = try DocumentConverter.extractText(from: file.path)

        XCTAssertEqual(text, "Bonjour Jarvis")
    }

    // MARK: - AppleScript path (injected, never launches real Pages/Numbers)

    func testPagesExtractionWritesExportedFileContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        DocumentConverter.runAppleScript = { source in
            // Simulate Pages actually exporting: find the target path the
            // real script embeds and write to it, same as the export
            // command would.
            guard let targetPath = Self.extractQuotedArgument(after: "to file", in: source) else {
                XCTFail("expected a target path in the generated script")
                return
            }
            try "contenu exporte".write(toFile: targetPath, atomically: true, encoding: .utf8)
        }

        let fakePages = root.appendingPathComponent("doc.pages")
        try "not real pages data".write(to: fakePages, atomically: true, encoding: .utf8)

        let text = try DocumentConverter.extractText(from: fakePages.path)

        XCTAssertEqual(text, "contenu exporte")
    }

    func testPagesExtractionAutomationFailureSuggestsManualExport() {
        DocumentConverter.runAppleScript = { _ in
            throw DocumentConverter.ConversionError.automationFailed("Pages n'a pas pu ouvrir le document.")
        }

        XCTAssertThrowsError(try DocumentConverter.extractText(from: "/tmp/whatever.pages")) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("bug connu d'Apple"), "should explain this is a known Apple bug, not blame the file")
            XCTAssertTrue(message.contains("Exporter vers"), "should point to the manual export menu path")
        }
    }

    func testUnsupportedFormatThrowsWithoutInvokingAutomation() {
        var called = false
        DocumentConverter.runAppleScript = { _ in called = true }

        XCTAssertThrowsError(try DocumentConverter.extractText(from: "/tmp/whatever.key"))
        XCTAssertFalse(called, "Keynote has no export path -- must fail before ever touching automation")
    }

    private static func extractQuotedArgument(after marker: String, in script: String) -> String? {
        guard let markerRange = script.range(of: marker) else { return nil }
        let remainder = script[markerRange.upperBound...]
        guard let firstQuote = remainder.firstIndex(of: "\""),
              let secondQuote = remainder[remainder.index(after: firstQuote)...].firstIndex(of: "\"") else { return nil }
        return String(remainder[remainder.index(after: firstQuote)..<secondQuote])
    }
}
