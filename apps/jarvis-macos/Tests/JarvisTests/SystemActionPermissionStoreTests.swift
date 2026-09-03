import XCTest
@testable import Jarvis

final class SystemActionPermissionStoreTests: XCTestCase {
    private func makeStore() -> SystemActionPermissionStore {
        let suiteName = "jarvis.tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return SystemActionPermissionStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    func testCapabilitiesStartDisabledAndUnconfirmed() {
        let store = makeStore()
        for capability in SystemActionCapability.allCases {
            XCTAssertFalse(store.isEnabled(capability))
            XCTAssertFalse(store.hasConfirmed(capability))
        }
    }

    func testEnableAndDisableRoundTrip() {
        let store = makeStore()
        store.setEnabled(true, for: .clickXcodeBuildButton)
        XCTAssertTrue(store.isEnabled(.clickXcodeBuildButton))
        XCTAssertFalse(store.isEnabled(.focusEditorWindow), "toggling one capability must not affect another")

        store.setEnabled(false, for: .clickXcodeBuildButton)
        XCTAssertFalse(store.isEnabled(.clickXcodeBuildButton))
    }

    func testDisablingClearsConfirmation() {
        let store = makeStore()
        store.setEnabled(true, for: .typeIntoFocusedEditorField)
        store.markConfirmed(.typeIntoFocusedEditorField)
        XCTAssertTrue(store.hasConfirmed(.typeIntoFocusedEditorField))

        store.setEnabled(false, for: .typeIntoFocusedEditorField)
        XCTAssertFalse(store.hasConfirmed(.typeIntoFocusedEditorField), "re-enabling later should require confirming again")
    }

    func testResetClearsBothFlags() {
        let store = makeStore()
        store.setEnabled(true, for: .focusEditorWindow)
        store.markConfirmed(.focusEditorWindow)

        store.reset(.focusEditorWindow)

        XCTAssertFalse(store.isEnabled(.focusEditorWindow))
        XCTAssertFalse(store.hasConfirmed(.focusEditorWindow))
    }
}
