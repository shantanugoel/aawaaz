import XCTest
@testable import Aawaaz

final class ModelManagerTests: XCTestCase {

    // MARK: - Model Persistence

    func testSelectedModelPersistence() {
        // Verify the UserDefaults key for selected model
        let key = "selectedModel"

        // Save a value
        UserDefaults.standard.set(WhisperModel.small.rawValue, forKey: key)
        let raw = UserDefaults.standard.string(forKey: key)
        XCTAssertEqual(raw, "small")

        let model = WhisperModel(rawValue: raw ?? "")
        XCTAssertEqual(model, .small)

        // Clean up
        UserDefaults.standard.removeObject(forKey: key)
    }

    func testSelectedDevicePersistence() {
        let key = "selectedAudioDeviceUID"

        let testUID = "test-device-\(UUID().uuidString)"
        UserDefaults.standard.set(testUID, forKey: key)
        let stored = UserDefaults.standard.string(forKey: key)
        XCTAssertEqual(stored, testUID)

        // Clean up
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - WhisperModel

    func testWhisperModelAllCases() {
        XCTAssertEqual(WhisperModel.allCases.count, 3)
        XCTAssertTrue(WhisperModel.allCases.contains(.small))
        XCTAssertTrue(WhisperModel.allCases.contains(.turbo))
        XCTAssertTrue(WhisperModel.allCases.contains(.largeV3))
    }

    func testWhisperModelRawValues() {
        XCTAssertEqual(WhisperModel.small.rawValue, "small")
        XCTAssertEqual(WhisperModel.turbo.rawValue, "turbo")
        XCTAssertEqual(WhisperModel.largeV3.rawValue, "large-v3")
    }

}
