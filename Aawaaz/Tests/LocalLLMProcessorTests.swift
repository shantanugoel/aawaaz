import XCTest
@testable import Aawaaz

final class LocalLLMProcessorTests: XCTestCase {

    // MARK: - capitalizeStartIfAppropriate

    func testCapitalizesProseLowercaseStart() {
        let ctx = InsertionContext(appName: "Notes", bundleIdentifier: "com.apple.Notes", fieldType: .multiLine)
        XCTAssertEqual(
            LocalLLMProcessor.capitalizeStartIfAppropriate("this is a test.", context: ctx),
            "This is a test."
        )
    }

    func testSkipsAlreadyCapitalized() {
        let ctx = InsertionContext(appName: "Notes", bundleIdentifier: "com.apple.Notes", fieldType: .multiLine)
        XCTAssertEqual(
            LocalLLMProcessor.capitalizeStartIfAppropriate("Already capitalized.", context: ctx),
            "Already capitalized."
        )
    }

    func testSkipsCodeContext() {
        let ctx = InsertionContext(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", fieldType: .multiLine)
        XCTAssertEqual(
            LocalLLMProcessor.capitalizeStartIfAppropriate("let x = 42", context: ctx),
            "let x = 42"
        )
    }

    func testSkipsTerminalContext() {
        let ctx = InsertionContext(appName: "Terminal", bundleIdentifier: "com.apple.Terminal", fieldType: .multiLine)
        XCTAssertEqual(
            LocalLLMProcessor.capitalizeStartIfAppropriate("git status", context: ctx),
            "git status"
        )
    }

    func testSkipsURL() {
        let ctx = InsertionContext(appName: "Safari", bundleIdentifier: "com.apple.Safari", fieldType: .singleLine)
        XCTAssertEqual(
            LocalLLMProcessor.capitalizeStartIfAppropriate("https://example.com/path", context: ctx),
            "https://example.com/path"
        )
    }

    func testSkipsAbsolutePath() {
        let ctx = InsertionContext(appName: "Notes", bundleIdentifier: "com.apple.Notes", fieldType: .multiLine)
        XCTAssertEqual(
            LocalLLMProcessor.capitalizeStartIfAppropriate("/usr/local/bin", context: ctx),
            "/usr/local/bin"
        )
    }

    func testSkipsHomePath() {
        let ctx = InsertionContext(appName: "Notes", bundleIdentifier: "com.apple.Notes", fieldType: .multiLine)
        XCTAssertEqual(
            LocalLLMProcessor.capitalizeStartIfAppropriate("~/Documents/file.txt", context: ctx),
            "~/Documents/file.txt"
        )
    }

    func testSkipsCLIFlag() {
        let ctx = InsertionContext(appName: "Notes", bundleIdentifier: "com.apple.Notes", fieldType: .multiLine)
        XCTAssertEqual(
            LocalLLMProcessor.capitalizeStartIfAppropriate("--force", context: ctx),
            "--force"
        )
    }

    func testSkipsHandle() {
        let ctx = InsertionContext(appName: "Notes", bundleIdentifier: "com.apple.Notes", fieldType: .multiLine)
        XCTAssertEqual(
            LocalLLMProcessor.capitalizeStartIfAppropriate("@admin check this", context: ctx),
            "@admin check this"
        )
    }

    func testSkipsEmail() {
        let ctx = InsertionContext(appName: "Notes", bundleIdentifier: "com.apple.Notes", fieldType: .multiLine)
        XCTAssertEqual(
            LocalLLMProcessor.capitalizeStartIfAppropriate("john@example.com", context: ctx),
            "john@example.com"
        )
    }

    func testCapitalizesSingleLineField() {
        let ctx = InsertionContext(appName: "Safari", bundleIdentifier: "com.apple.Safari", fieldType: .singleLine)
        XCTAssertEqual(
            LocalLLMProcessor.capitalizeStartIfAppropriate("search for restaurants", context: ctx),
            "Search for restaurants"
        )
    }

    func testCapitalizesWwwSkipped() {
        let ctx = InsertionContext(appName: "Safari", bundleIdentifier: "com.apple.Safari", fieldType: .singleLine)
        XCTAssertEqual(
            LocalLLMProcessor.capitalizeStartIfAppropriate("www.example.com", context: ctx),
            "www.example.com"
        )
    }

    // MARK: - buildSystemPrompt context injection

    func testSystemPromptIncludesContextInstruction() {
        let ctx = InsertionContext(appName: "Notes", bundleIdentifier: "com.apple.Notes", fieldType: .multiLine)
        // Context instruction only included when flag is true
        let promptWithContext = LocalLLMProcessor.buildSystemPrompt(for: ctx, cleanupLevel: .medium, includeSurroundingContextInstruction: true)
        XCTAssertTrue(promptWithContext.contains("context_before"), "System prompt should mention context_before block when enabled")
        XCTAssertTrue(promptWithContext.contains("Do not copy or continue it"), "System prompt should warn against copying context")

        // Without flag, context instruction should be absent
        let promptWithout = LocalLLMProcessor.buildSystemPrompt(for: ctx, cleanupLevel: .medium)
        XCTAssertFalse(promptWithout.contains("context_before"), "System prompt should NOT mention context_before when disabled")
    }

    func testSystemPromptCodeCategory() {
        let ctx = InsertionContext(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", fieldType: .multiLine)
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: ctx, cleanupLevel: .full)
        XCTAssertTrue(prompt.contains("code"), "Code context should mention code in prompt")
    }

    func testSystemPromptTerminalCategory() {
        let ctx = InsertionContext(appName: "Terminal", bundleIdentifier: "com.apple.Terminal", fieldType: .multiLine)
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: ctx, cleanupLevel: .full)
        XCTAssertTrue(prompt.contains("commands"), "Terminal context should mention commands in prompt")
    }

    // MARK: - Phase 6: Prompt composition by cleanup level

    func testSystemPromptHindiParticleRuleIncludedAlways() {
        let ctx = InsertionContext(appName: "Notes", bundleIdentifier: "com.apple.Notes", fieldType: .multiLine)
        for level in [CleanupLevel.light, .medium, .full] {
            let prompt = LocalLLMProcessor.buildSystemPrompt(for: ctx, cleanupLevel: level)
            XCTAssertTrue(prompt.contains("ki"), "Hindi particle rule should be present for \(level)")
        }
    }

    func testSystemPromptSelfCorrectionOnlyForMediumFull() {
        let ctx = InsertionContext(appName: "Notes", bundleIdentifier: "com.apple.Notes", fieldType: .multiLine)

        let lightPrompt = LocalLLMProcessor.buildSystemPrompt(for: ctx, cleanupLevel: .light)
        XCTAssertFalse(lightPrompt.contains("well actually"), "Light cleanup should NOT include self-correction instruction")
        XCTAssertFalse(lightPrompt.contains("sixty dollars"), "Light cleanup should NOT include self-correction example")

        let mediumPrompt = LocalLLMProcessor.buildSystemPrompt(for: ctx, cleanupLevel: .medium)
        XCTAssertTrue(mediumPrompt.contains("well actually"), "Medium cleanup should include self-correction instruction")
        XCTAssertTrue(mediumPrompt.contains("sixty dollars"), "Medium cleanup should include self-correction example")

        let fullPrompt = LocalLLMProcessor.buildSystemPrompt(for: ctx, cleanupLevel: .full)
        XCTAssertTrue(fullPrompt.contains("well actually"), "Full cleanup should include self-correction instruction")
        XCTAssertTrue(fullPrompt.contains("sixty dollars"), "Full cleanup should include self-correction example")
    }

    func testSystemPromptConditionalExamplesPresent() {
        let ctx = InsertionContext(appName: "Notes", bundleIdentifier: "com.apple.Notes", fieldType: .multiLine)
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: ctx, cleanupLevel: .medium)

        // Verify all 3 conditional examples are present
        XCTAssertTrue(prompt.contains("sixty dollars"), "Should include self-correction example")
        XCTAssertTrue(prompt.contains("Everyone seemed to like it"), "Should include sentence-splitting example")
        XCTAssertTrue(prompt.contains("jaldi start karo"), "Should include Hinglish continuity example")
    }

    // MARK: - Content drop guard with self-correction markers

    func testOutputDropGuardRelaxedForSelfCorrection() {
        // Input with "well actually" should use relaxed threshold
        let input = "The budget is ten thousand well actually fifteen thousand."
        let output = "The budget is fifteen thousand."
        XCTAssertFalse(
            LocalLLMProcessor.outputDroppedTooMuch(input: input, output: output),
            "Self-correction output should NOT be rejected when input contains correction marker"
        )
    }

    func testOutputDropGuardStrictWithoutMarker() {
        // Same drop ratio but without correction marker should be rejected
        let input = "The budget is ten thousand and also fifteen thousand."
        let output = "The budget is fifteen thousand."
        XCTAssertTrue(
            LocalLLMProcessor.outputDroppedTooMuch(input: input, output: output),
            "Heavy content drop without correction marker should be rejected"
        )
    }
}
