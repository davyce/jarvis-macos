import XCTest
@testable import Jarvis

/// Exercises `JarvisBridge.performLimuleBridgeAction`'s gating (master
/// toggle -> token availability -> execute -> always audit) entirely
/// through injected doubles, mirroring `JarvisBridgeSystemActionTests` --
/// never touches a real Keychain read, a real HTTP call, or UserDefaults.
final class JarvisBridgeLimuleBridgeActionTests: XCTestCase {
    private var recordedAudit: [LimuleBridgeAuditEntry] = []
    private var executeCallCount = 0

    override func setUp() {
        super.setUp()
        recordedAudit = []
        executeCallCount = 0

        JarvisBridge.limuleBridgeEnabled = { true }
        JarvisBridge.limuleBridgeTokenGate = { true }
        JarvisBridge.limuleBridgeAuditRecorder = { [weak self] entry in self?.recordedAudit.append(entry) }
        JarvisBridge.limuleBridgeAuditLoader = { _ in [] }
        JarvisBridge.limuleBridgeExecute = { [weak self] _ in
            self?.executeCallCount += 1
            return LimuleBridgeClient.ActionResult(succeeded: true, message: "ok", data: nil)
        }
    }

    override func tearDown() {
        JarvisBridge.limuleBridgeEnabled = { LimuleBridgeSettings.isEnabled }
        JarvisBridge.limuleBridgeTokenGate = { LimuleBridgeAuthentication.token() != nil }
        JarvisBridge.limuleBridgeAuditRecorder = { LocalDatabase.shared.insertLimuleBridgeAudit($0) }
        JarvisBridge.limuleBridgeAuditLoader = { LocalDatabase.shared.loadLimuleBridgeAudit(limit: $0) }
        JarvisBridge.limuleBridgeExecute = LimuleBridgeClient.perform
        super.tearDown()
    }

    func testDisabledBlocksExecutionWithoutTokenCheckOrAudit() async {
        JarvisBridge.limuleBridgeEnabled = { false }
        JarvisBridge.limuleBridgeTokenGate = { XCTFail("must not check token when disabled"); return false }

        let result = await JarvisBridge.performLimuleBridgeAction(.health)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.localizedCaseInsensitiveContains("desactiv"))
        XCTAssertEqual(executeCallCount, 0)
        XCTAssertTrue(recordedAudit.isEmpty)
    }

    func testMissingTokenBlocksExecutionWithoutAudit() async {
        JarvisBridge.limuleBridgeTokenGate = { false }

        let result = await JarvisBridge.performLimuleBridgeAction(.windows)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(executeCallCount, 0)
        XCTAssertTrue(recordedAudit.isEmpty)
    }

    func testSuccessRecordsAuditAndReturnsSucceeded() async {
        let result = await JarvisBridge.performLimuleBridgeAction(.click(x: 1, y: 2))

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(executeCallCount, 1)
        XCTAssertEqual(recordedAudit.count, 1)
        XCTAssertEqual(recordedAudit.first?.outcome, .success)
        XCTAssertEqual(recordedAudit.first?.route, "/click")
    }

    func testExecutionFailureRecordsAuditAndReturnsFailure() async {
        JarvisBridge.limuleBridgeExecute = { [weak self] _ in
            self?.executeCallCount += 1
            throw LimuleBridgeClient.ServiceError.businessError(code: "window_not_found", message: "No such window")
        }

        let result = await JarvisBridge.performLimuleBridgeAction(.press(title: "Nope", app: nil))

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.message, "No such window")
        XCTAssertEqual(recordedAudit.count, 1)
        XCTAssertEqual(recordedAudit.first?.outcome, .failure)
        XCTAssertEqual(recordedAudit.first?.detail, "No such window")
    }

    func testAuditSummaryNeverIncludesRawSensitiveTextVerbatimBeyondTruncation() async {
        let longText = String(repeating: "x", count: 200)
        _ = await JarvisBridge.performLimuleBridgeAction(.sendMessage(recipient: "someone", text: longText))

        let recordedSummary = recordedAudit.first?.summary ?? ""
        XCTAssertLessThan(recordedSummary.count, longText.count, "must be truncated, not the full message")
    }

    func testRecentFailureOnSameRouteIsAppendedAsReminder() async {
        JarvisBridge.limuleBridgeAuditLoader = { _ in
            [LimuleBridgeAuditEntry(route: "/press", summary: "Clic sur \u{201C}Nope\u{201D}", outcome: .failure, detail: "No such window", createdAt: .now)]
        }
        JarvisBridge.limuleBridgeExecute = { [weak self] _ in
            self?.executeCallCount += 1
            throw LimuleBridgeClient.ServiceError.businessError(code: "window_not_found", message: "Still no such window")
        }

        let result = await JarvisBridge.performLimuleBridgeAction(.press(title: "Nope", app: nil))

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.contains("Still no such window"))
        XCTAssertTrue(result.message.contains("deja echoue"))
        XCTAssertTrue(result.message.contains("No such window"), "should quote the prior failure's own detail")
        // The audit trail's own detail must stay clean (just this
        // failure's reason), not duplicated with the reminder text.
        XCTAssertEqual(recordedAudit.first?.detail, "Still no such window")
    }

    func testFailureOnDifferentRouteGetsNoReminder() async {
        JarvisBridge.limuleBridgeAuditLoader = { _ in
            [LimuleBridgeAuditEntry(route: "/click", summary: "Clic", outcome: .failure, detail: "unrelated failure", createdAt: .now)]
        }
        JarvisBridge.limuleBridgeExecute = { [weak self] _ in
            self?.executeCallCount += 1
            throw LimuleBridgeClient.ServiceError.businessError(code: "window_not_found", message: "No such window")
        }

        let result = await JarvisBridge.performLimuleBridgeAction(.press(title: "Nope", app: nil))

        XCTAssertEqual(result.message, "No such window")
    }

    func testStaleFailureOlderThan24HoursGetsNoReminder() async {
        JarvisBridge.limuleBridgeAuditLoader = { _ in
            [LimuleBridgeAuditEntry(route: "/press", summary: "Clic", outcome: .failure, detail: "old failure", createdAt: Date.now.addingTimeInterval(-25 * 3600))]
        }
        JarvisBridge.limuleBridgeExecute = { [weak self] _ in
            self?.executeCallCount += 1
            throw LimuleBridgeClient.ServiceError.businessError(code: "window_not_found", message: "No such window")
        }

        let result = await JarvisBridge.performLimuleBridgeAction(.press(title: "Nope", app: nil))

        XCTAssertEqual(result.message, "No such window")
    }
}
