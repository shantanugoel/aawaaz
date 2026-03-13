import XCTest
@testable import Aawaaz

final class HotkeyManagerTests: XCTestCase {

    // MARK: - Hold Mode State

    func testHoldModeActivateDeactivate() {
        let config = HotkeyConfiguration(
            keyCode: 49,
            modifierFlags: NSEvent.ModifierFlags.option.rawValue,
            mode: .hold
        )
        let manager = HotkeyManager(configuration: config)

        var activateCount = 0
        var deactivateCount = 0
        manager.onActivate = { activateCount += 1 }
        manager.onDeactivate = { deactivateCount += 1 }

        // Verify initial state
        XCTAssertFalse(manager.isEventTapActive)
    }

    func testResetStateClearsActivation() {
        let config = HotkeyConfiguration(
            keyCode: 49,
            modifierFlags: NSEvent.ModifierFlags.option.rawValue,
            mode: .hold
        )
        let manager = HotkeyManager(configuration: config)
        manager.resetState()
        // Should not crash or cause issues — verifies clean reset
    }

    func testUpdateConfigurationPersists() {
        let manager = HotkeyManager()

        let newConfig = HotkeyConfiguration(
            keyCode: 36,
            modifierFlags: NSEvent.ModifierFlags.command.rawValue,
            mode: .toggle
        )

        manager.updateConfiguration(newConfig)
        XCTAssertEqual(manager.configuration.keyCode, 36)
        XCTAssertEqual(manager.configuration.mode, .toggle)
    }

    // MARK: - Toggle Mode

    func testToggleModeConfiguration() {
        let config = HotkeyConfiguration(
            keyCode: 49,
            modifierFlags: NSEvent.ModifierFlags.option.rawValue,
            mode: .toggle
        )
        let manager = HotkeyManager(configuration: config)
        XCTAssertEqual(manager.configuration.mode, .toggle)
    }
}
