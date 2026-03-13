import XCTest
@testable import Aawaaz

final class HotkeyConfigurationTests: XCTestCase {

    // MARK: - Display String

    func testDefaultDisplayString() {
        let config = HotkeyConfiguration.defaultConfiguration
        XCTAssertEqual(config.displayString, "⌥Space")
    }

    func testCommandShiftDisplayString() {
        let config = HotkeyConfiguration(
            keyCode: 2, // 'd'
            modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            mode: .hold
        )
        XCTAssertEqual(config.displayString, "⇧⌘D")
    }

    func testControlOptionDisplayString() {
        let config = HotkeyConfiguration(
            keyCode: 36, // Return
            modifierFlags: NSEvent.ModifierFlags([.control, .option]).rawValue,
            mode: .toggle
        )
        XCTAssertEqual(config.displayString, "⌃⌥Return")
    }

    // MARK: - Persistence

    func testSaveAndLoad() {
        let config = HotkeyConfiguration(
            keyCode: 12, // 'q'
            modifierFlags: NSEvent.ModifierFlags.command.rawValue,
            mode: .toggle
        )

        // Save to a unique key to avoid polluting real defaults
        let key = "hotkeyConfiguration_test_\(UUID().uuidString)"
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: key)
        }

        guard let data = UserDefaults.standard.data(forKey: key),
              let loaded = try? JSONDecoder().decode(HotkeyConfiguration.self, from: data) else {
            XCTFail("Failed to load saved configuration")
            return
        }

        XCTAssertEqual(loaded.keyCode, 12)
        XCTAssertEqual(loaded.modifierFlags, NSEvent.ModifierFlags.command.rawValue)
        XCTAssertEqual(loaded.mode, .toggle)

        // Clean up
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Equality

    func testEquality() {
        let a = HotkeyConfiguration(keyCode: 49, modifierFlags: NSEvent.ModifierFlags.option.rawValue, mode: .hold)
        let b = HotkeyConfiguration(keyCode: 49, modifierFlags: NSEvent.ModifierFlags.option.rawValue, mode: .hold)
        XCTAssertEqual(a, b)
    }

    func testInequalityKeyCode() {
        let a = HotkeyConfiguration(keyCode: 49, modifierFlags: NSEvent.ModifierFlags.option.rawValue, mode: .hold)
        let b = HotkeyConfiguration(keyCode: 36, modifierFlags: NSEvent.ModifierFlags.option.rawValue, mode: .hold)
        XCTAssertNotEqual(a, b)
    }

    func testInequalityMode() {
        let a = HotkeyConfiguration(keyCode: 49, modifierFlags: NSEvent.ModifierFlags.option.rawValue, mode: .hold)
        let b = HotkeyConfiguration(keyCode: 49, modifierFlags: NSEvent.ModifierFlags.option.rawValue, mode: .toggle)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Unknown Key Code

    func testUnknownKeyCodeDisplayString() {
        let config = HotkeyConfiguration(
            keyCode: 200,
            modifierFlags: 0,
            mode: .hold
        )
        XCTAssertTrue(config.displayString.contains("Key(200)"))
    }
}
