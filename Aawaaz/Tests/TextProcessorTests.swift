import XCTest
@testable import Aawaaz

final class TextProcessorTests: XCTestCase {

    private let processor = TextProcessor()

    // MARK: - Integration: Pipeline Order

    func testSelfCorrectionRunsBeforeFillerRemoval() {
        // "actually no" must be detected as correction before "um" is removed
        let config = TextProcessingConfig(
            fillerRemovalEnabled: true,
            selfCorrectionEnabled: true,
            fillerWords: TextProcessingConfig.defaultFillerWords
        )
        XCTAssertEqual(
            processor.process("Turn left, actually no, um, turn right", config: config),
            "turn right"
        )
    }

    func testBothStepsEnabled() {
        let config = TextProcessingConfig(
            fillerRemovalEnabled: true,
            selfCorrectionEnabled: true,
            fillerWords: TextProcessingConfig.defaultFillerWords
        )
        XCTAssertEqual(
            processor.process("Um I was going to say, scratch that, basically the project is done", config: config),
            "the project is done"
        )
    }

    // MARK: - Config Toggles

    func testFillerRemovalDisabled() {
        let config = TextProcessingConfig(
            fillerRemovalEnabled: false,
            selfCorrectionEnabled: true,
            fillerWords: TextProcessingConfig.defaultFillerWords
        )
        let result = processor.process("Um I went to the store", config: config)
        XCTAssertEqual(result, "Um I went to the store")
    }

    func testSelfCorrectionDisabled() {
        let config = TextProcessingConfig(
            fillerRemovalEnabled: true,
            selfCorrectionEnabled: false,
            fillerWords: TextProcessingConfig.defaultFillerWords
        )
        let result = processor.process("Turn left, actually no, turn right", config: config)
        // Self-correction is off, so "actually no" is not treated as a correction marker.
        // Filler removal doesn't match "actually no" as a filler.
        XCTAssertEqual(result, "Turn left, actually no, turn right")
    }

    func testBothDisabledReturnsOriginal() {
        let config = TextProcessingConfig(
            fillerRemovalEnabled: false,
            selfCorrectionEnabled: false,
            fillerWords: TextProcessingConfig.defaultFillerWords
        )
        let input = "Um, actually no, let me rephrase, uh, the answer is 42"
        XCTAssertEqual(processor.process(input, config: config), input)
    }

    // MARK: - Edge Cases

    func testEmptyText() {
        let config = TextProcessingConfig.default
        XCTAssertEqual(processor.process("", config: config), "")
    }

    func testCleanTextPassesThrough() {
        let config = TextProcessingConfig.default
        let input = "The project is going well and we should ship next week"
        XCTAssertEqual(processor.process(input, config: config), input)
    }
}
