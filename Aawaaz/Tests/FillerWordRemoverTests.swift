import XCTest
@testable import Aawaaz

final class FillerWordRemoverTests: XCTestCase {

    private let remover = FillerWordRemover()
    private let defaults = TextProcessingConfig.defaultFillerWords

    // MARK: - Basic Removal

    func testRemovesSingleFillerWord() {
        XCTAssertEqual(
            remover.removeFillers(from: "um I went to the store", fillerWords: defaults),
            "I went to the store"
        )
    }

    func testRemovesMultipleFillerWords() {
        XCTAssertEqual(
            remover.removeFillers(from: "um I uh went to the store", fillerWords: defaults),
            "I went to the store"
        )
    }

    func testRemovesFillerAtEnd() {
        XCTAssertEqual(
            remover.removeFillers(from: "I went to the store um", fillerWords: defaults),
            "I went to the store"
        )
    }

    func testRemovesFillerInMiddle() {
        XCTAssertEqual(
            remover.removeFillers(from: "I went uh to the store", fillerWords: defaults),
            "I went to the store"
        )
    }

    // MARK: - Multi-Word Fillers

    func testRemovesMultiWordFiller() {
        XCTAssertEqual(
            remover.removeFillers(from: "I was you know going to the store", fillerWords: defaults),
            "I was going to the store"
        )
    }

    func testRemovesMultiWordFillerAtStart() {
        XCTAssertEqual(
            remover.removeFillers(from: "You know I was going to the store", fillerWords: defaults),
            "I was going to the store"
        )
    }

    // MARK: - Case Insensitivity

    func testCaseInsensitiveRemoval() {
        XCTAssertEqual(
            remover.removeFillers(from: "UM I went to the store", fillerWords: defaults),
            "I went to the store"
        )
    }

    func testMixedCaseRemoval() {
        XCTAssertEqual(
            remover.removeFillers(from: "Basically I went to the store", fillerWords: defaults),
            "I went to the store"
        )
    }

    // MARK: - No False Positives

    func testKeepsLegitimateWords() {
        // "um" and "uh" should not match partial words
        XCTAssertEqual(
            remover.removeFillers(from: "The umbrella was found", fillerWords: defaults),
            "The umbrella was found"
        )
    }

    func testKeepsWordContainingFiller() {
        XCTAssertEqual(
            remover.removeFillers(from: "The humble drummer played", fillerWords: defaults),
            "The humble drummer played"
        )
    }

    func testDoesNotMatchPartialUh() {
        XCTAssertEqual(
            remover.removeFillers(from: "She said uhh wait", fillerWords: ["uh"]),
            "She said uhh wait"
        )
    }

    // MARK: - Comma Handling

    func testRemovesFillerWithTrailingComma() {
        XCTAssertEqual(
            remover.removeFillers(from: "Um, I went to the store", fillerWords: defaults),
            "I went to the store"
        )
    }

    func testCleansUpDoubleCommas() {
        XCTAssertEqual(
            remover.removeFillers(from: "I went, um, to the store", fillerWords: defaults),
            "I went to the store"
        )
    }

    // MARK: - Whitespace Cleanup

    func testCollapsesMultipleSpaces() {
        XCTAssertEqual(
            remover.removeFillers(from: "I   um   went to the store", fillerWords: defaults),
            "I went to the store"
        )
    }

    func testTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(
            remover.removeFillers(from: "  um I went to the store uh  ", fillerWords: defaults),
            "I went to the store"
        )
    }

    // MARK: - Edge Cases

    func testEmptyTextReturnsEmpty() {
        XCTAssertEqual(
            remover.removeFillers(from: "", fillerWords: defaults),
            ""
        )
    }

    func testEmptyFillerListReturnsOriginal() {
        XCTAssertEqual(
            remover.removeFillers(from: "um I went to the store", fillerWords: []),
            "um I went to the store"
        )
    }

    func testAllFillersRemovedReturnsEmpty() {
        XCTAssertEqual(
            remover.removeFillers(from: "um uh", fillerWords: defaults),
            ""
        )
    }

    func testCustomFillerWords() {
        let custom = ["well", "okay"]
        XCTAssertEqual(
            remover.removeFillers(from: "Well okay I went to the store", fillerWords: custom),
            "I went to the store"
        )
    }

    func testMultipleAdjacentFillers() {
        XCTAssertEqual(
            remover.removeFillers(from: "um uh basically I went to the store", fillerWords: defaults),
            "I went to the store"
        )
    }

    func testNoFillersInText() {
        XCTAssertEqual(
            remover.removeFillers(from: "I went to the store", fillerWords: defaults),
            "I went to the store"
        )
    }

    // MARK: - Context-Sensitive "you know" (Guard Words)

    func testKeepsYouKnowAfterDo() {
        XCTAssertEqual(
            remover.removeFillers(from: "Do you know where it is?", fillerWords: defaults),
            "Do you know where it is?"
        )
    }

    func testKeepsYouKnowAfterDid() {
        XCTAssertEqual(
            remover.removeFillers(from: "Did you know that whales sing?", fillerWords: defaults),
            "Did you know that whales sing?"
        )
    }

    func testKeepsYouKnowAfterDont() {
        XCTAssertEqual(
            remover.removeFillers(from: "I don't you know what happened", fillerWords: defaults),
            "I don't you know what happened"
        )
    }

    func testKeepsYouKnowAfterIf() {
        XCTAssertEqual(
            remover.removeFillers(from: "Let me check if you know the answer", fillerWords: defaults),
            "Let me check if you know the answer"
        )
    }

    func testRemovesFillerYouKnowAfterNonGuardWord() {
        XCTAssertEqual(
            remover.removeFillers(from: "I was you know going to the store", fillerWords: defaults),
            "I was going to the store"
        )
    }

    func testRemovesFillerYouKnowAtStart() {
        XCTAssertEqual(
            remover.removeFillers(from: "You know I was going to the store", fillerWords: defaults),
            "I was going to the store"
        )
    }

    func testMixedVerbAndFillerYouKnow() {
        // "Do you know" is a verb phrase (keep), second "you know" is a filler (remove).
        // The comma after the first "know" was in the original text and is preserved.
        XCTAssertEqual(
            remover.removeFillers(from: "Do you know, you know, where it is?", fillerWords: defaults),
            "Do you know, where it is?"
        )
    }
}
