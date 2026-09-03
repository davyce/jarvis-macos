import XCTest
@testable import Jarvis

/// Exercises the gating pipeline in `JarvisBridge.performSystemAction`
/// (permission -> accessibility trust -> one-time confirmation -> execute ->
/// audit) entirely through injected doubles, so it never touches real OS
/// Accessibility permissions, AXUIElement/CGEvent calls, or an NSAlert.
final class JarvisBridgeSystemActionTests: XCTestCase {
    private var permissionStore: SystemActionPermissionStore!
    private var recordedAudit: [SystemActionAuditEntry] = []
    private var executeCallCount = 0
    private var confirmationCallCount = 0

    private let project = JarvisProject(id: "test", name: "Test", rootPath: "/tmp/jarvis-test", order: 0, sourceType: .folder)

    override func setUp() {
        super.setUp()
        let suiteName = "jarvis.tests.bridge.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        permissionStore = SystemActionPermissionStore(defaults: UserDefaults(suiteName: suiteName)!)

        recordedAudit = []
        executeCallCount = 0
        confirmationCallCount = 0

        JarvisBridge.permissionStore = permissionStore
        JarvisBridge.accessibilityGate = { true }
        JarvisBridge.confirmationHandler = { [weak self] _ in
            self?.confirmationCallCount += 1
            return true
        }
        JarvisBridge.auditRecorder = { [weak self] entry in self?.recordedAudit.append(entry) }
        JarvisBridge.executeSystemAction = { [weak self] _, _ in
            self?.executeCallCount += 1
            return JarvisBridge.ActionResult(succeeded: true, message: "ok")
        }
    }

    override func tearDown() {
        JarvisBridge.permissionStore = .shared
        JarvisBridge.accessibilityGate = { AccessibilityPermission.requestIfNeeded() }
        JarvisBridge.confirmationHandler = SystemActionConfirmation.confirm
        JarvisBridge.auditRecorder = { LocalDatabase.shared.insertSystemActionAudit($0) }
        JarvisBridge.executeSystemAction = { action, project in
            switch action {
            case .clickXcodeBuildButton: return SystemActionExecutor.clickXcodeBuildButton()
            case .focusEditorWindow: return SystemActionExecutor.focusEditorWindow(project: project)
            case .typeIntoFocusedEditorField(let text): return SystemActionExecutor.typeIntoFocusedEditorField(text: text, project: project)
            }
        }
        super.tearDown()
    }

    func testDisabledCapabilityBlocksExecutionWithoutTouchingAnythingElse() {
        // clickXcodeBuildButton is left disabled (default).
        let result = JarvisBridge.perform(.system(.clickXcodeBuildButton), on: project)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.localizedCaseInsensitiveContains("desactiv"))
        XCTAssertEqual(executeCallCount, 0)
        XCTAssertEqual(confirmationCallCount, 0)
        XCTAssertTrue(recordedAudit.isEmpty)
    }

    func testMissingAccessibilityTrustBlocksExecution() {
        permissionStore.setEnabled(true, for: .focusEditorWindow)
        JarvisBridge.accessibilityGate = { false }

        let result = JarvisBridge.perform(.system(.focusEditorWindow), on: project)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.localizedCaseInsensitiveContains("accessibilit"))
        XCTAssertEqual(executeCallCount, 0)
        XCTAssertEqual(confirmationCallCount, 0)
    }

    func testDeclinedConfirmationBlocksExecutionAndLeavesCapabilityUnconfirmed() {
        permissionStore.setEnabled(true, for: .typeIntoFocusedEditorField)
        JarvisBridge.confirmationHandler = { [weak self] _ in
            self?.confirmationCallCount += 1
            return false
        }

        let result = JarvisBridge.perform(.system(.typeIntoFocusedEditorField(text: "hello")), on: project)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(executeCallCount, 0)
        XCTAssertEqual(confirmationCallCount, 1)
        XCTAssertFalse(permissionStore.hasConfirmed(.typeIntoFocusedEditorField))
        XCTAssertEqual(recordedAudit.count, 1)
        XCTAssertEqual(recordedAudit.first?.outcome, .declined)
    }

    func testFirstExecutionAsksOnceThenSkipsConfirmationOnSubsequentRuns() {
        permissionStore.setEnabled(true, for: .clickXcodeBuildButton)

        let first = JarvisBridge.perform(.system(.clickXcodeBuildButton), on: project)
        XCTAssertTrue(first.succeeded)
        XCTAssertEqual(confirmationCallCount, 1)
        XCTAssertEqual(executeCallCount, 1)
        XCTAssertTrue(permissionStore.hasConfirmed(.clickXcodeBuildButton))

        let second = JarvisBridge.perform(.system(.clickXcodeBuildButton), on: project)
        XCTAssertTrue(second.succeeded)
        XCTAssertEqual(confirmationCallCount, 1, "confirmation should not be asked again after the first accepted run")
        XCTAssertEqual(executeCallCount, 2)

        XCTAssertEqual(recordedAudit.count, 2)
        XCTAssertEqual(recordedAudit.map(\.outcome), [.success, .success])
    }

    func testAuditLogRecordsExecutionFailures() {
        permissionStore.setEnabled(true, for: .focusEditorWindow)
        JarvisBridge.executeSystemAction = { [weak self] _, _ in
            self?.executeCallCount += 1
            return JarvisBridge.ActionResult(succeeded: false, message: "VS Code introuvable")
        }

        let result = JarvisBridge.perform(.system(.focusEditorWindow), on: project)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(recordedAudit.count, 1)
        XCTAssertEqual(recordedAudit.first?.outcome, .failure)
        XCTAssertEqual(recordedAudit.first?.detail, "VS Code introuvable")
        XCTAssertEqual(recordedAudit.first?.capability, .focusEditorWindow)
    }

    func testExistingFourActionsAreUnaffectedByTheSystemActionGating() {
        // Sanity check that the pre-existing chantier still bypasses all of
        // the new gating (no permission store / accessibility / confirmation
        // involved) since it never routes through `.system(...)`.
        JarvisBridge.accessibilityGate = { XCTFail("openInFinder must not consult the accessibility gate"); return false }

        let result = JarvisBridge.perform(.openInFinder, on: project)
        XCTAssertFalse(result.succeeded, "the fixture project path does not exist, but the important part is which code path ran")
    }
}
