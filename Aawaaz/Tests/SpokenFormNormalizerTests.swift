import XCTest
@testable import Aawaaz

/// Unit tests for ``SpokenFormNormalizer``.
///
/// Tests both unambiguous patterns (always converted) and context-dependent
/// patterns (URLs, emails, paths, labels, commands).
final class SpokenFormNormalizerTests: XCTestCase {

    // MARK: - Unambiguous Patterns

    func testQuestionMark() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("is this correct question mark"),
            "is this correct?"
        )
    }

    func testExclamationMark() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("that is amazing exclamation mark"),
            "that is amazing!"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("wow exclamation point"),
            "wow!"
        )
    }

    func testParentheses() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("add open paren value close paren"),
            "add (value)"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("see open parenthesis note close parenthesis"),
            "see (note)"
        )
        // Alternate forms: start/end, closed
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("parenthesis start less than three parenthesis closed"),
            "(less than three)"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("start parenthesis note end parenthesis"),
            "(note)"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("parenthesis open value parenthesis close"),
            "(value)"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("start paren x end paren"),
            "(x)"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("closed parenthesis at the end"),
            ") at the end"
        )
    }

    func testBrackets() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("array open bracket 0 close bracket"),
            "array [0]"
        )
    }

    func testUnderscore() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("user underscore name"),
            "user_name"
        )
    }

    func testAmpersand() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("rock ampersand roll"),
            "rock & roll"
        )
    }

    func testAtSign() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("send to at sign admin"),
            "send to @admin"
        )
    }

    func testPercentSign() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("90 percent sign complete"),
            "90% complete"
        )
    }

    func testDollarSign() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("it costs dollar sign 50"),
            "it costs $50"
        )
    }

    func testEqualsSign() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("x equals sign 5"),
            "x = 5"
        )
    }

    // MARK: - URL Patterns

    func testHTTPSUrl() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("the website is https colon slash slash github dot com slash aawaaz"),
            "the website is https://github.com/aawaaz"
        )
    }

    func testHTTPUrl() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("go to http colon slash slash example dot com"),
            "go to http://example.com"
        )
    }

    // MARK: - Email Patterns

    func testSimpleEmail() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("send to john at example dot com"),
            "send to john@example.com"
        )
    }

    func testDottedEmail() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("email john dot smith at example dot com"),
            "email john.smith@example.com"
        )
    }

    // MARK: - Path Patterns

    func testAPIPath() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("the endpoint is slash api slash v2 slash users"),
            "the endpoint is /api/v2/users"
        )
    }

    func testFilePathWithExtension() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("open slash users slash john slash report dot pdf"),
            "open /users/john/report.pdf"
        )
    }

    // MARK: - Dotted Names (extensions/TLDs)

    func testNextJS() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("use next dot js for the frontend"),
            "use next.js for the frontend"
        )
    }

    func testReportPDF() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("download the report dot pdf"),
            "download the report.pdf"
        )
    }

    func testDotInProse() {
        // "dot" in regular prose should NOT be converted when the extension
        // is not a known file extension or TLD
        let input = "I like the dot on the i"
        XCTAssertEqual(SpokenFormNormalizer.normalize(input), input)
    }

    // MARK: - Label Colons

    func testReColon() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("re colon project update"),
            "Re: Project update"
        )
    }

    func testBugReportColon() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("bug report colon app crashes"),
            "Bug report: App crashes"
        )
    }

    func testSubjectColon() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("subject colon meeting tomorrow"),
            "Subject: Meeting tomorrow"
        )
    }

    func testNonLabelColon() {
        // "colon" after a non-label word should stay as "colon"
        let input = "the colon is part of the body"
        XCTAssertEqual(SpokenFormNormalizer.normalize(input), input)
    }

    func testValueFollowerLabelColonNoCapitalize() {
        // Value-follower labels (from, to, cc, etc.) should NOT capitalize the next word
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("from colon john at example dot com"),
            "From: john@example.com"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("to colon admin"),
            "To: admin"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("cc colon team"),
            "Cc: team"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("input colon foo_bar"),
            "Input: foo_bar"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("output colon next dot js"),
            "Output: next.js"
        )
    }

    func testSentenceStartLabelColonCapitalizes() {
        // Sentence-start labels should capitalize the next word
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("note colon remember to check"),
            "Note: Remember to check"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("warning colon do not delete"),
            "Warning: Do not delete"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("todo colon fix the bug"),
            "Todo: Fix the bug"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("step colon open the file"),
            "Step: Open the file"
        )
    }

    // MARK: - Command Patterns

    func testDoubleDash() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("add dash dash force flag"),
            "add --force flag"
        )
    }

    func testSingleDashFlag() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("use dash n option"),
            "use -n option"
        )
    }

    func testMultipleDashes() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("run dash dash save dash dev"),
            "run --save dash dev"
        )
    }

    // MARK: - Ellipsis

    func testEllipsis() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("well dot dot dot I'm not sure"),
            "well... I'm not sure"
        )
    }

    // MARK: - Combined Patterns

    func testURLWithPath() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("visit https colon slash slash api dot example dot com slash v2 slash users"),
            "visit https://api.example.com/v2/users"
        )
    }

    func testPassthrough() {
        // Regular prose should pass through unchanged
        let input = "I think we should schedule a meeting for next week"
        XCTAssertEqual(SpokenFormNormalizer.normalize(input), input)
    }

    func testEmptyString() {
        XCTAssertEqual(SpokenFormNormalizer.normalize(""), "")
    }

    // MARK: - Case Insensitivity

    func testCaseInsensitive() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("add Question Mark at the end"),
            "add? at the end"
        )
    }

    // MARK: - Negative Cases (should NOT normalize)

    func testSlashInProse() {
        // Single "slash" in prose should NOT be converted to a path
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("use slash for division"),
            "use slash for division"
        )
    }

    func testSlashKey() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("press the slash key"),
            "press the slash key"
        )
    }

    func testDashInProse() {
        // "dash" followed by a multi-letter word should stay as-is
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("add a dash between words"),
            "add a dash between words"
        )
    }
}
