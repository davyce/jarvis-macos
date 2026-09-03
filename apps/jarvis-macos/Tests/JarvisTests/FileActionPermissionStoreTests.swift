import XCTest
@testable import Jarvis

final class FileActionPermissionStoreTests: XCTestCase {
    private func makeStore() -> FileActionPermissionStore {
        let suiteName = "jarvis.tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return FileActionPermissionStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    func testCapabilitiesStartDisabledAndUnconfirmed() {
        let store = makeStore()
        for capability in FileActionCapability.allCases {
            XCTAssertFalse(store.isEnabled(capability))
            XCTAssertFalse(store.hasConfirmed(capability))
        }
    }

    func testEnableAndDisableRoundTrip() {
        let store = makeStore()
        store.setEnabled(true, for: .writeFile)
        XCTAssertTrue(store.isEnabled(.writeFile))
        XCTAssertFalse(store.isEnabled(.deleteFile), "toggling one capability must not affect another")

        store.setEnabled(false, for: .writeFile)
        XCTAssertFalse(store.isEnabled(.writeFile))
    }

    func testDisablingClearsConfirmation() {
        let store = makeStore()
        store.setEnabled(true, for: .duplicateFile)
        store.markConfirmed(.duplicateFile)
        XCTAssertTrue(store.hasConfirmed(.duplicateFile))

        store.setEnabled(false, for: .duplicateFile)
        XCTAssertFalse(store.hasConfirmed(.duplicateFile), "re-enabling later should require confirming again")
    }

    func testResetClearsBothFlags() {
        let store = makeStore()
        store.setEnabled(true, for: .moveFile)
        store.markConfirmed(.moveFile)

        store.reset(.moveFile)

        XCTAssertFalse(store.isEnabled(.moveFile))
        XCTAssertFalse(store.hasConfirmed(.moveFile))
    }
}
