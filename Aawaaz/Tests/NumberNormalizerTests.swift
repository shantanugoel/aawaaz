import XCTest
@testable import Aawaaz

/// Unit tests for ``NumberNormalizer``.
///
/// Tests conversion of spoken number words to their numeric representations,
/// including cardinals, ordinals, decimals, phone numbers, and mixed text.
final class NumberNormalizerTests: XCTestCase {

    // MARK: - Cardinal Numbers (Single Digits)

    func testSingleDigitOne() {
        XCTAssertEqual(NumberNormalizer.normalize("one"), "1")
    }

    func testSingleDigitZero() {
        XCTAssertEqual(NumberNormalizer.normalize("zero"), "0")
    }

    func testSingleDigitNine() {
        XCTAssertEqual(NumberNormalizer.normalize("nine"), "9")
    }

    // MARK: - Cardinal Numbers (Teens)

    func testTeenThirteen() {
        XCTAssertEqual(NumberNormalizer.normalize("thirteen"), "13")
    }

    func testTeenNineteen() {
        XCTAssertEqual(NumberNormalizer.normalize("nineteen"), "19")
    }

    // MARK: - Cardinal Numbers (Tens)

    func testTenTwenty() {
        XCTAssertEqual(NumberNormalizer.normalize("twenty"), "20")
    }

    func testTenFifty() {
        XCTAssertEqual(NumberNormalizer.normalize("fifty"), "50")
    }

    // MARK: - Cardinal Numbers (Compound Tens)

    func testCompoundTwentyThree() {
        XCTAssertEqual(NumberNormalizer.normalize("twenty three"), "23")
    }

    func testCompoundNinetyNine() {
        XCTAssertEqual(NumberNormalizer.normalize("ninety nine"), "99")
    }

    // MARK: - Cardinal Numbers (Hundreds)

    func testOneHundred() {
        XCTAssertEqual(NumberNormalizer.normalize("one hundred"), "100")
    }

    func testAHundred() {
        XCTAssertEqual(NumberNormalizer.normalize("a hundred"), "100")
    }

    func testTwoHundred() {
        XCTAssertEqual(NumberNormalizer.normalize("two hundred"), "200")
    }

    // MARK: - Cardinal Numbers (Compound Hundreds)

    func testOneHundredTwentyThree() {
        XCTAssertEqual(NumberNormalizer.normalize("one hundred twenty three"), "123")
    }

    func testThreeHundredAndFifty() {
        XCTAssertEqual(NumberNormalizer.normalize("three hundred and fifty"), "350")
    }

    // MARK: - Cardinal Numbers (Thousands)

    func testOneThousand() {
        XCTAssertEqual(NumberNormalizer.normalize("one thousand"), "1000")
    }

    func testAThousand() {
        XCTAssertEqual(NumberNormalizer.normalize("a thousand"), "1000")
    }

    func testTwoThousand() {
        XCTAssertEqual(NumberNormalizer.normalize("two thousand"), "2000")
    }

    // MARK: - Cardinal Numbers (Compound Thousands)

    func testTwoThousandTwentySix() {
        XCTAssertEqual(NumberNormalizer.normalize("two thousand twenty six"), "2026")
    }

    // MARK: - Cardinal Numbers (Large)

    func testOneMillion() {
        XCTAssertEqual(NumberNormalizer.normalize("one million"), "1000000")
    }

    func testTwoBillion() {
        XCTAssertEqual(NumberNormalizer.normalize("two billion"), "2000000000")
    }

    // MARK: - Ordinal Numbers (Simple)

    func testOrdinalFirst() {
        XCTAssertEqual(NumberNormalizer.normalize("first"), "1st")
    }

    func testOrdinalSecond() {
        XCTAssertEqual(NumberNormalizer.normalize("second"), "2nd")
    }

    func testOrdinalThird() {
        XCTAssertEqual(NumberNormalizer.normalize("third"), "3rd")
    }

    func testOrdinalFourth() {
        XCTAssertEqual(NumberNormalizer.normalize("fourth"), "4th")
    }

    // MARK: - Ordinal Numbers (Teens)

    func testOrdinalEleventh() {
        XCTAssertEqual(NumberNormalizer.normalize("eleventh"), "11th")
    }

    func testOrdinalTwelfth() {
        XCTAssertEqual(NumberNormalizer.normalize("twelfth"), "12th")
    }

    func testOrdinalThirteenth() {
        XCTAssertEqual(NumberNormalizer.normalize("thirteenth"), "13th")
    }

    // MARK: - Ordinal Numbers (Tens)

    func testOrdinalTwentieth() {
        XCTAssertEqual(NumberNormalizer.normalize("twentieth"), "20th")
    }

    func testOrdinalThirtieth() {
        XCTAssertEqual(NumberNormalizer.normalize("thirtieth"), "30th")
    }

    // MARK: - Ordinal Numbers (Compound)

    func testOrdinalTwentyFirst() {
        XCTAssertEqual(NumberNormalizer.normalize("twenty first"), "21st")
    }

    func testOrdinalTwentySecond() {
        XCTAssertEqual(NumberNormalizer.normalize("twenty second"), "22nd")
    }

    func testOrdinalTwentyThird() {
        XCTAssertEqual(NumberNormalizer.normalize("twenty third"), "23rd")
    }

    func testOrdinalThirtyFifth() {
        XCTAssertEqual(NumberNormalizer.normalize("thirty fifth"), "35th")
    }

    // MARK: - Ordinal Numbers (Hundredth)

    func testOrdinalHundredth() {
        XCTAssertEqual(NumberNormalizer.normalize("hundredth"), "100th")
    }

    // MARK: - Decimal Numbers

    func testDecimalThreePointFive() {
        XCTAssertEqual(NumberNormalizer.normalize("three point five"), "3.5")
    }

    func testDecimalNinetyNinePointFive() {
        XCTAssertEqual(NumberNormalizer.normalize("ninety nine point five"), "99.5")
    }

    func testDecimalThreePointOneFour() {
        XCTAssertEqual(NumberNormalizer.normalize("three point one four"), "3.14")
    }

    func testDecimalZeroPointFive() {
        XCTAssertEqual(NumberNormalizer.normalize("zero point five"), "0.5")
    }

    // MARK: - Mixed Text

    func testMixedTextWithCardinal() {
        XCTAssertEqual(
            NumberNormalizer.normalize("I have twenty three apples"),
            "I have 23 apples"
        )
    }

    func testMixedTextWithChapter() {
        XCTAssertEqual(
            NumberNormalizer.normalize("chapter twenty one"),
            "chapter 21"
        )
    }

    func testMixedTextWithVersion() {
        XCTAssertEqual(
            NumberNormalizer.normalize("version two point three"),
            "version 2.3"
        )
    }

    // MARK: - Ambiguous Sequences (ones followed by tens)

    func testTwoThirtyNotCombined() {
        // "two thirty" is ambiguous (time 2:30? or 230?). Each word should
        // convert independently so the LLM can interpret from context.
        XCTAssertEqual(NumberNormalizer.normalize("two thirty"), "2 30")
    }

    func testThirtyTwoIsCombined() {
        // "thirty two" is valid English — tens before ones.
        XCTAssertEqual(NumberNormalizer.normalize("thirty two"), "32")
    }

    func testFiveFortyInContext() {
        XCTAssertEqual(
            NumberNormalizer.normalize("the meeting is at five forty"),
            "the meeting is at 5 40"
        )
    }

    func testThreeFiftyNotCombined() {
        XCTAssertEqual(NumberNormalizer.normalize("three fifty"), "3 50")
    }

    func testNineTwentyNotCombined() {
        XCTAssertEqual(NumberNormalizer.normalize("nine twenty"), "9 20")
    }

    func testOneHundredTwentyStillWorks() {
        // ones + multiplier + tens is valid: "one hundred twenty"
        XCTAssertEqual(NumberNormalizer.normalize("one hundred twenty"), "120")
    }

    func testTwoHundredFiftyStillWorks() {
        XCTAssertEqual(NumberNormalizer.normalize("two hundred fifty"), "250")
    }

    func testFiveThousandSixtyStillWorks() {
        // ones + thousand + tens is valid via multiplier
        XCTAssertEqual(NumberNormalizer.normalize("five thousand sixty"), "5060")
    }

    func testOneHundredTwentyThreeStillWorks() {
        // ones + hundred + tens + ones remains valid
        XCTAssertEqual(NumberNormalizer.normalize("one hundred twenty three"), "123")
    }

    // MARK: - Multiple Numbers in One Sentence

    func testTwoSeparateNumbers() {
        XCTAssertEqual(
            NumberNormalizer.normalize("buy twelve eggs and three loaves"),
            "buy 12 eggs and 3 loaves"
        )
    }

    func testMultipleNumbersInSentence() {
        XCTAssertEqual(
            NumberNormalizer.normalize("there are twenty cats and thirty dogs"),
            "there are 20 cats and 30 dogs"
        )
    }

    func testNumberAtStartAndEnd() {
        XCTAssertEqual(
            NumberNormalizer.normalize("five people came and left at nine"),
            "5 people came and left at 9"
        )
    }

    // MARK: - Ordinals in Context

    func testOrdinalInSentence() {
        XCTAssertEqual(
            NumberNormalizer.normalize("the twenty first of march"),
            "the 21st of march"
        )
    }

    func testOrdinalAfterMultiplier() {
        XCTAssertEqual(
            NumberNormalizer.normalize("the one hundred fifth episode"),
            "the 105th episode"
        )
    }

    func testOrdinalThousandth() {
        XCTAssertEqual(NumberNormalizer.normalize("thousandth"), "1000th")
    }

    // MARK: - Compound Thousands

    func testThreeThousandFourHundredFiftySix() {
        XCTAssertEqual(
            NumberNormalizer.normalize("three thousand four hundred fifty six"),
            "3456"
        )
    }

    func testTenThousand() {
        XCTAssertEqual(NumberNormalizer.normalize("ten thousand"), "10000")
    }

    func testFiftyThousand() {
        XCTAssertEqual(NumberNormalizer.normalize("fifty thousand"), "50000")
    }

    // MARK: - "And" Handling

    func testAndBetweenHundredAndTens() {
        XCTAssertEqual(
            NumberNormalizer.normalize("five hundred and twelve"),
            "512"
        )
    }

    func testAndBetweenNonNumbers() {
        // "and" between normal words should pass through
        XCTAssertEqual(
            NumberNormalizer.normalize("cats and dogs"),
            "cats and dogs"
        )
    }

    func testTrailingAndNotConsumed() {
        // "and" at end of a number should not be swallowed
        XCTAssertEqual(
            NumberNormalizer.normalize("twenty and"),
            "20 and"
        )
    }

    // MARK: - "A" Handling

    func testABeforeNonMultiplier() {
        // "a" before a non-multiplier word should pass through
        XCTAssertEqual(
            NumberNormalizer.normalize("a dog"),
            "a dog"
        )
    }

    func testAHundredAndFifty() {
        XCTAssertEqual(NumberNormalizer.normalize("a hundred and fifty"), "150")
    }

    func testAThousandAndOne() {
        XCTAssertEqual(NumberNormalizer.normalize("a thousand and one"), "1001")
    }

    func testAInMiddleOfSentence() {
        // "a" mid-sentence should not trigger number conversion
        XCTAssertEqual(
            NumberNormalizer.normalize("this is a test"),
            "this is a test"
        )
    }

    // MARK: - Decimal Edge Cases

    func testPointWithoutPrecedingNumber() {
        // "point" alone is not a decimal
        XCTAssertEqual(
            NumberNormalizer.normalize("the point is clear"),
            "the point is clear"
        )
    }

    func testDecimalWithMultipleDigits() {
        XCTAssertEqual(
            NumberNormalizer.normalize("one point two five"),
            "1.25"
        )
    }

    func testDecimalInSentence() {
        XCTAssertEqual(
            NumberNormalizer.normalize("it weighs three point five kilograms"),
            "it weighs 3.5 kilograms"
        )
    }

    // MARK: - Edge Cases

    func testEmptyString() {
        XCTAssertEqual(NumberNormalizer.normalize(""), "")
    }

    func testNoNumberWords() {
        XCTAssertEqual(
            NumberNormalizer.normalize("hello world"),
            "hello world"
        )
    }

    func testAndAloneNotConverted() {
        XCTAssertEqual(
            NumberNormalizer.normalize("and"),
            "and"
        )
    }

    func testAAloneNotConverted() {
        XCTAssertEqual(
            NumberNormalizer.normalize("a"),
            "a"
        )
    }

    func testCaseInsensitive() {
        XCTAssertEqual(NumberNormalizer.normalize("Twenty Three"), "23")
    }

    // MARK: - Passthrough

    func testPassthroughCleanText() {
        let input = "The project is going well"
        XCTAssertEqual(NumberNormalizer.normalize(input), input)
    }
}
