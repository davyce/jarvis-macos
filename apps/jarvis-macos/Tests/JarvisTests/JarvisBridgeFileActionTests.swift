import XCTest
@testable import Jarvis

/// Exercises the gating pipeline in `JarvisBridge.performFileAction`
/// (permission -> one-time confirmation -> execute -> audit) through
/// injected doubles for the store/confirmation/audit, but real
/// `LocalFileService` calls against a disposable temp directory -- unlike
/// the AXUIElement system actions, file operations are simple enough to
/// trigger real success/failure without needing to fake the filesystem.
final class JarvisBridgeFileActionTests: XCTestCase {
    private var permissionStore: FileActionPermissionStore!
    private var recordedAudit: [FileActionAuditEntry] = []
    private var confirmationCallCount = 0
    private var root: URL!

    override func setUp() {
        super.setUp()
        let suiteName = "jarvis.tests.bridge.files.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        permissionStore = FileActionPermissionStore(defaults: UserDefaults(suiteName: suiteName)!)

        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        recordedAudit = []
        confirmationCallCount = 0

        JarvisBridge.filePermissionStore = permissionStore
        JarvisBridge.fileConfirmationHandler = { [weak self] _, _ in
            self?.confirmationCallCount += 1
            return true
        }
        JarvisBridge.fileAuditRecorder = { [weak self] entry in self?.recordedAudit.append(entry) }
        let searchRoot = root!
        LocalFileService.defaultSearchRoots = { [searchRoot] }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        JarvisBridge.filePermissionStore = .shared
        JarvisBridge.fileConfirmationHandler = FileActionConfirmation.confirm
        JarvisBridge.fileAuditRecorder = { LocalDatabase.shared.insertFileActionAudit($0) }
        LocalFileService.defaultSearchRoots = LocalFileService.realDefaultSearchRoots
        super.tearDown()
    }

    func testDisabledCapabilityBlocksExecutionWithoutTouchingAnythingElse() async {
        let target = root.appendingPathComponent("note.txt")
        // writeFile is left disabled (default).
        let result = await JarvisBridge.performFileAction(.write(path: target.path, content: "hello"))

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.localizedCaseInsensitiveContains("desactiv"))
        XCTAssertEqual(confirmationCallCount, 0)
        XCTAssertTrue(recordedAudit.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testDeclinedConfirmationBlocksExecutionAndLeavesCapabilityUnconfirmed() async {
        permissionStore.setEnabled(true, for: .writeFile)
        JarvisBridge.fileConfirmationHandler = { [weak self] _, _ in
            self?.confirmationCallCount += 1
            return false
        }
        let target = root.appendingPathComponent("note.txt")

        let result = await JarvisBridge.performFileAction(.write(path: target.path, content: "hello"))

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(confirmationCallCount, 1)
        XCTAssertFalse(permissionStore.hasConfirmed(.writeFile))
        XCTAssertEqual(recordedAudit.count, 1)
        XCTAssertEqual(recordedAudit.first?.outcome, .declined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testFirstExecutionAsksOnceThenSkipsConfirmationOnSubsequentRuns() async throws {
        permissionStore.setEnabled(true, for: .duplicateFile)
        let original = root.appendingPathComponent("notes.txt")
        try "content".write(to: original, atomically: true, encoding: .utf8)

        let first = await JarvisBridge.performFileAction(.duplicate(path: original.path))
        XCTAssertTrue(first.succeeded)
        XCTAssertEqual(confirmationCallCount, 1)
        XCTAssertTrue(permissionStore.hasConfirmed(.duplicateFile))

        let second = await JarvisBridge.performFileAction(.duplicate(path: original.path))
        XCTAssertTrue(second.succeeded)
        XCTAssertEqual(confirmationCallCount, 1, "confirmation should not be asked again after the first accepted run")

        XCTAssertEqual(recordedAudit.count, 2)
        XCTAssertEqual(recordedAudit.map(\.outcome), [.success, .success])
    }

    func testAuditLogRecordsExecutionFailures() async {
        permissionStore.setEnabled(true, for: .moveFile)
        let missingSource = root.appendingPathComponent("does-not-exist.txt")
        let destination = root.appendingPathComponent("dest.txt")

        let result = await JarvisBridge.performFileAction(.move(from: missingSource.path, to: destination.path))

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(recordedAudit.count, 1)
        XCTAssertEqual(recordedAudit.first?.outcome, .failure)
        XCTAssertEqual(recordedAudit.first?.kind, .move)
    }

    func testReadOnlyActionsNeverInvokeConfirmationHandlerAndAreAudited() async throws {
        try "hello world".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let searchResult = await JarvisBridge.performFileAction(.search(query: "a.txt"))
        let listResult = await JarvisBridge.performFileAction(.list(path: root.path))
        let readResult = await JarvisBridge.performFileAction(.readText(path: root.appendingPathComponent("a.txt").path))

        XCTAssertTrue(searchResult.succeeded)
        XCTAssertTrue(listResult.succeeded)
        XCTAssertTrue(readResult.succeeded)
        XCTAssertEqual(readResult.content, "hello world")
        XCTAssertEqual(confirmationCallCount, 0, "read-only actions must never consult the confirmation handler")
        XCTAssertEqual(recordedAudit.count, 3)
        XCTAssertEqual(Set(recordedAudit.map(\.kind)), [.search, .list, .read])
    }
}
