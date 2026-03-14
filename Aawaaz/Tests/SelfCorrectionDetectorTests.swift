import XCTest
@testable import Aawaaz

final class SelfCorrectionDetectorTests: XCTestCase {

    private let detector = SelfCorrectionDetector()

    // MARK: - Basic Correction Patterns

    func testActuallyNoCorrection() {
        XCTAssertEqual(
            detector.detectAndResolve("Turn left, actually no, turn right"),
            "Turn right"
        )
    }

    func testIMeanCorrectionWithComma() {
        XCTAssertEqual(
            detector.detectAndResolve("Go to the park, I mean the beach"),
            "The beach"
        )
    }

    func testWaitCorrectionWithComma() {
        XCTAssertEqual(
            detector.detectAndResolve("The meeting is at 3, wait, it's at 4"),
            "It's at 4"
        )
    }

    func testSorryCorrectionWithComma() {
        XCTAssertEqual(
            detector.detectAndResolve("His name is John, sorry, James"),
            "James"
        )
    }

    func testNoNoCorrection() {
        XCTAssertEqual(
            detector.detectAndResolve("I want pizza, no no, I want pasta"),
            "I want pasta"
        )
    }

    func testLetMeRephraseCorrection() {
        XCTAssertEqual(
            detector.detectAndResolve("The system is broken, let me rephrase, the system needs updating"),
            "The system needs updating"
        )
    }

    func testScratchThatCorrection() {
        XCTAssertEqual(
            detector.detectAndResolve("Send the email now, scratch that, send it tomorrow"),
            "Send it tomorrow"
        )
    }

    // MARK: - Multiple Corrections

    func testMultipleCorrectionKeepsLast() {
        XCTAssertEqual(
            detector.detectAndResolve("Go left, wait, go right, actually no, go straight"),
            "Go straight"
        )
    }

    // MARK: - No Correction Present

    func testNoCorrection() {
        let input = "I went to the store and bought some milk"
        XCTAssertEqual(detector.detectAndResolve(input), input)
    }

    func testEmptyText() {
        XCTAssertEqual(detector.detectAndResolve(""), "")
    }

    // MARK: - Word Boundary Safety

    func testDoesNotMatchPartialWord() {
        let input = "I was waiting for the bus"
        XCTAssertEqual(detector.detectAndResolve(input), input)
    }

    // MARK: - False Positive Prevention (Context-Dependent Markers)

    func testWaitAsLegitimateWord() {
        let input = "Wait for me at the corner"
        XCTAssertEqual(detector.detectAndResolve(input), input)
    }

    func testSorryAsLegitimateWord() {
        let input = "The sorry state of affairs was obvious"
        XCTAssertEqual(detector.detectAndResolve(input), input)
    }

    func testIMeanAsLegitimatePhrase() {
        let input = "I mean business when I say that"
        XCTAssertEqual(detector.detectAndResolve(input), input)
    }

    func testWaitAtStartStillWorks() {
        XCTAssertEqual(
            detector.detectAndResolve("Wait, let's go to the park instead"),
            "Let's go to the park instead"
        )
    }

    func testSorryAtStartStillWorks() {
        XCTAssertEqual(
            detector.detectAndResolve("Sorry, I meant next Tuesday"),
            "I meant next Tuesday"
        )
    }

    // MARK: - Case Insensitivity

    func testCaseInsensitiveMatching() {
        XCTAssertEqual(
            detector.detectAndResolve("Turn left, ACTUALLY NO, turn right"),
            "Turn right"
        )
    }

    // MARK: - Correction at Start

    func testCorrectionMarkerAtStart() {
        XCTAssertEqual(
            detector.detectAndResolve("Actually no, let's go to the park"),
            "Let's go to the park"
        )
    }

    // MARK: - Correction Marker at End

    func testCorrectionMarkerAtEndKeepsOriginal() {
        let input = "I want to go to the park actually no"
        XCTAssertEqual(detector.detectAndResolve(input), input)
    }

    // MARK: - No No No Pattern

    func testNoNoNoCorrection() {
        XCTAssertEqual(
            detector.detectAndResolve("Book the flight, no no no, cancel everything"),
            "Cancel everything"
        )
    }

    // MARK: - Whitespace Handling

    func testTrimsWhitespace() {
        XCTAssertEqual(
            detector.detectAndResolve("  Turn left, actually no,   turn right  "),
            "Turn right"
        )
    }
}
