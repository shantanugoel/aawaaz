import XCTest
@testable import Aawaaz

final class TextInsertionManagerTests: XCTestCase {

    // MARK: - Per-App Preferences

    func testSetAndGetPreferredMethod() {
        let manager = TextInsertionManager()
        let bundleID = "com.test.app.\(UUID().uuidString)"

        // Initially nil
        XCTAssertNil(manager.preferredMethod(forBundleID: bundleID))

        // Set a preference
        manager.setPreferredMethod(.keystrokeSimulation, forBundleID: bundleID)
        XCTAssertEqual(manager.preferredMethod(forBundleID: bundleID), .keystrokeSimulation)

        // Update preference
        manager.setPreferredMethod(.clipboardOnly, forBundleID: bundleID)
        XCTAssertEqual(manager.preferredMethod(forBundleID: bundleID), .clipboardOnly)

        // Clear preference
        manager.setPreferredMethod(nil, forBundleID: bundleID)
        XCTAssertNil(manager.preferredMethod(forBundleID: bundleID))
    }

    func testPreferredMethodPersistence() {
        let bundleID = "com.test.persistence.\(UUID().uuidString)"

        // Set with one instance
        let manager1 = TextInsertionManager()
        manager1.setPreferredMethod(.accessibility, forBundleID: bundleID)

        // Read with another instance (UserDefaults is shared)
        let manager2 = TextInsertionManager()
        XCTAssertEqual(manager2.preferredMethod(forBundleID: bundleID), .accessibility)

        // Clean up
        manager1.setPreferredMethod(nil, forBundleID: bundleID)
    }
}
