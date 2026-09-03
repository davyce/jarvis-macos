import XCTest
@testable import Jarvis

/// Exercises `JarvisBridge.performLimuleObservation`'s per-route JSON
/// decoding -- the actual point of this entry point (`content` must carry
/// the real payload, not just `action.auditSummary`) -- entirely through
/// injected doubles, mirroring `JarvisBridgeLimuleBridgeActionTests`.
final class JarvisBridgeLimuleObservationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        JarvisBridge.limuleBridgeEnabled = { true }
        JarvisBridge.limuleBridgeTokenGate = { true }
        JarvisBridge.limuleBridgeAuditRecorder = { _ in }
        JarvisBridge.limuleBridgeAuditLoader = { _ in [] }
    }

    override func tearDown() {
        JarvisBridge.limuleBridgeEnabled = { LimuleBridgeSettings.isEnabled }
        JarvisBridge.limuleBridgeTokenGate = { LimuleBridgeAuthentication.token() != nil }
        JarvisBridge.limuleBridgeAuditRecorder = { LocalDatabase.shared.insertLimuleBridgeAudit($0) }
        JarvisBridge.limuleBridgeAuditLoader = { LocalDatabase.shared.loadLimuleBridgeAudit(limit: $0) }
        JarvisBridge.limuleBridgeExecute = LimuleBridgeClient.perform
        super.tearDown()
    }

    private func stub(_ json: String) {
        JarvisBridge.limuleBridgeExecute = { _ in
            LimuleBridgeClient.ActionResult(succeeded: true, message: "ignored", data: Data(json.utf8))
        }
    }

    func testHealthDecodesStatusAndAccessibility() async {
        stub(#"{"status":"ok","accessibility":true}"#)
        let result = await JarvisBridge.performLimuleObservation(.health)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.content?.contains("ok") ?? false)
        XCTAssertTrue(result.content?.localizedCaseInsensitiveContains("oui") ?? false)
    }

    func testDisplaysDecodesFormattedList() async {
        stub(#"{"displays":[{"id":1,"width":1920,"height":1080,"is_main":true}]}"#)
        let result = await JarvisBridge.performLimuleObservation(.displays)
        XCTAssertEqual(result.content, "Ecran 1 : 1920x1080 (principal)")
    }

    func testClipboardReturnsRealTextVerbatim() async {
        stub(#"{"text":"un secret copie par l'utilisateur"}"#)
        let result = await JarvisBridge.performLimuleObservation(.getClipboard)
        XCTAssertEqual(result.content, "un secret copie par l'utilisateur")
    }

    func testEmptyClipboardReturnsExplicitEmptyMessage() async {
        stub(#"{"text":""}"#)
        let result = await JarvisBridge.performLimuleObservation(.getClipboard)
        XCTAssertEqual(result.content, "Le presse-papiers est vide.")
    }

    func testWindowsDecodesAppAndTitlePairs() async {
        stub(#"{"windows":[{"app":"Xcode","title":"Jarvis.xcodeproj","x":0,"y":0,"width":100,"height":100,"window_number":1}]}"#)
        let result = await JarvisBridge.performLimuleObservation(.windows)
        XCTAssertEqual(result.content, "Xcode -- Jarvis.xcodeproj")
    }

    func testSnapshotDecodesAppNameAndEmbedsTree() async {
        stub(#"{"app":"Safari","tree":{"role":"window","children":[]}}"#)
        let result = await JarvisBridge.performLimuleObservation(.snapshot(app: nil))
        XCTAssertTrue(result.content?.contains("Safari") ?? false)
        XCTAssertTrue(result.content?.contains("role") ?? false)
    }

    func testBrowserTextDecodesTextAndURL() async {
        stub(#"{"ok":true,"text":"contenu de la page","url":"https://example.com"}"#)
        let result = await JarvisBridge.performLimuleObservation(.browserText)
        XCTAssertTrue(result.content?.contains("contenu de la page") ?? false)
        XCTAssertTrue(result.content?.contains("https://example.com") ?? false)
    }

    func testLongClipboardTextIsTruncatedNotSilentlyDropped() async {
        let longText = String(repeating: "a", count: 5000)
        stub(#"{"text":"\#(longText)"}"#)
        let result = await JarvisBridge.performLimuleObservation(.getClipboard)
        XCTAssertLessThan(result.content?.count ?? Int.max, longText.count)
        XCTAssertTrue(result.content?.contains("tronque") ?? false)
    }

    func testMalformedResponseDegradesToNilContentNotCrash() async {
        JarvisBridge.limuleBridgeExecute = { _ in
            LimuleBridgeClient.ActionResult(succeeded: true, message: "ignored", data: Data("not json".utf8))
        }
        let result = await JarvisBridge.performLimuleObservation(.getClipboard)
        XCTAssertTrue(result.succeeded)
        XCTAssertNil(result.content)
    }

    func testGateFailureNeverDecodesAnything() async {
        JarvisBridge.limuleBridgeEnabled = { false }
        let result = await JarvisBridge.performLimuleObservation(.windows)
        XCTAssertFalse(result.succeeded)
        XCTAssertNil(result.content)
    }
}
