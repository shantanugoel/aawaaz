import XCTest
@testable import Aawaaz

final class CleanupLevelTests: XCTestCase {

    // MARK: - CleanupLevel Enum

    func testCleanupLevelRawValues() {
        XCTAssertEqual(CleanupLevel.light.rawValue, "light")
        XCTAssertEqual(CleanupLevel.medium.rawValue, "medium")
        XCTAssertEqual(CleanupLevel.full.rawValue, "full")
    }

    func testCleanupLevelDisplayNames() {
        XCTAssertEqual(CleanupLevel.light.displayName, "Light")
        XCTAssertEqual(CleanupLevel.medium.displayName, "Medium")
        XCTAssertEqual(CleanupLevel.full.displayName, "Full")
    }

    func testCleanupLevelCodable() throws {
        for level in CleanupLevel.allCases {
            let data = try JSONEncoder().encode(level)
            let decoded = try JSONDecoder().decode(CleanupLevel.self, from: data)
            XCTAssertEqual(decoded, level)
        }
    }

    func testCleanupLevelPersistence() {
        let key = "llm.cleanupLevel"
        let savedValue = UserDefaults.standard.string(forKey: key)
        defer {
            if let savedValue {
                UserDefaults.standard.set(savedValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        CleanupLevel.full.save()
        XCTAssertEqual(CleanupLevel.load(), .full)

        CleanupLevel.light.save()
        XCTAssertEqual(CleanupLevel.load(), .light)

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(CleanupLevel.load(), .medium, "Default should be medium")
    }

    // MARK: - PostProcessingMode Enum

    func testPostProcessingModeRawValues() {
        XCTAssertEqual(PostProcessingMode.off.rawValue, "off")
        XCTAssertEqual(PostProcessingMode.local.rawValue, "local")
    }

    func testPostProcessingModePersistence() {
        let key = "llm.postProcessingMode"
        let savedValue = UserDefaults.standard.string(forKey: key)
        defer {
            if let savedValue {
                UserDefaults.standard.set(savedValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        PostProcessingMode.local.save()
        XCTAssertEqual(PostProcessingMode.load(), .local)

        PostProcessingMode.off.save()
        XCTAssertEqual(PostProcessingMode.load(), .off)

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(PostProcessingMode.load(), .off, "Default should be off")
    }

    // MARK: - Prompt Construction: Light Level

    func testLightPromptFixesGrammar() {
        let context = InsertionContext(
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            fieldType: .multiLine
        )
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: .light)

        XCTAssert(prompt.contains("Fix grammar and punctuation"), "Light prompt should fix grammar")
    }

    func testLightPromptDoesNotRemoveFillers() {
        let context = InsertionContext.unknown
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: .light)

        XCTAssert(prompt.contains("Do NOT remove any words"), "Light prompt should keep fillers")
    }

    func testLightPromptHasNoCategoryInstruction() {
        let context = InsertionContext(
            appName: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            fieldType: .multiLine
        )
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: .light)

        XCTAssertFalse(prompt.contains("Format for chat"), "Light prompt should not include category formatting")
    }

    func testLightPromptPreservesHindiEnglish() {
        let context = InsertionContext.unknown
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: .light)

        XCTAssert(prompt.contains("Hindi and English"), "Light prompt should mention Hindi/English")
    }

    // MARK: - Prompt Construction: Medium Level

    func testMediumPromptImprovesStructure() {
        let context = InsertionContext.unknown
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: .medium)

        XCTAssert(prompt.contains("Improve sentence structure"), "Medium prompt should improve structure")
        XCTAssert(prompt.contains("capitalization"), "Medium prompt should fix capitalization")
    }

    func testMediumPromptHandlesSelfCorrections() {
        let context = InsertionContext.unknown
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: .medium)

        XCTAssert(prompt.contains("corrects themselves"), "Medium prompt should handle self-corrections")
        XCTAssert(prompt.contains("smallest possible edit"), "Medium prompt should prefer minimal rewrites")
        XCTAssert(prompt.contains("stable prefix intact"), "Medium prompt should preserve stable prefix")
    }

    func testMediumPromptHasNoCategoryInstruction() {
        let context = InsertionContext(
            appName: "Mail",
            bundleIdentifier: "com.apple.mail",
            fieldType: .multiLine
        )
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: .medium)

        XCTAssertFalse(prompt.contains("Format for email"), "Medium prompt should not include category formatting")
    }

    // MARK: - Prompt Construction: Full Level

    func testFullPromptRemovesFillers() {
        let context = InsertionContext.unknown
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: .full)

        XCTAssert(prompt.contains("Remove obvious filler words"), "Full prompt should remove fillers")
        XCTAssert(prompt.contains("smallest possible edit"), "Full prompt should prefer minimal rewrites")
    }

    func testFullPromptIncludesCategoryForEmail() {
        let context = InsertionContext(
            appName: "Mail",
            bundleIdentifier: "com.apple.mail",
            fieldType: .multiLine
        )
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: .full)

        XCTAssert(prompt.contains("Format for email"), "Full prompt should include email formatting")
        XCTAssert(prompt.contains("professional tone"), "Full prompt should mention professional tone for email")
    }

    func testFullPromptIncludesCategoryForChat() {
        let context = InsertionContext(
            appName: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            fieldType: .multiLine
        )
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: .full)

        XCTAssert(prompt.contains("Format for chat"), "Full prompt should include chat formatting")
        XCTAssert(prompt.contains("casual tone"), "Full prompt should mention casual tone for chat")
    }

    func testFullPromptIncludesCategoryForCode() {
        let context = InsertionContext(
            appName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            fieldType: .multiLine
        )
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: .full)

        XCTAssert(prompt.contains("Format for code editor"), "Full prompt should include code formatting")
        XCTAssert(prompt.contains("preserve code"), "Full prompt should preserve code in code editors")
    }

    func testFullPromptIncludesCategoryForTerminal() {
        let context = InsertionContext(
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            fieldType: .singleLine
        )
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: .full)

        XCTAssert(prompt.contains("Format for terminal"), "Full prompt should include terminal formatting")
        XCTAssert(prompt.contains("preserve commands"), "Full prompt should preserve commands in terminal")
    }

    func testFullPromptIncludesCategoryForDocument() {
        let context = InsertionContext(
            appName: "Pages",
            bundleIdentifier: "com.apple.iWork.Pages",
            fieldType: .multiLine
        )
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: .full)

        XCTAssert(prompt.contains("Format for document"), "Full prompt should include document formatting")
    }

    func testFullPromptFallsBackForBrowser() {
        let context = InsertionContext(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            fieldType: .webArea
        )
        let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: .full)

        XCTAssert(prompt.contains("Format naturally for general use"), "Browser should get generic formatting")
    }

    // MARK: - Field Type Constraints

    func testSingleLineConstraintAtAllLevels() {
        let context = InsertionContext(
            appName: "Spotlight",
            bundleIdentifier: "com.apple.Spotlight",
            fieldType: .singleLine
        )

        for level in CleanupLevel.allCases {
            let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: level)
            XCTAssert(
                prompt.contains("single-line field"),
                "\(level.displayName) prompt should include single-line constraint"
            )
        }
    }

    func testMultiLineHasNoFieldConstraint() {
        let context = InsertionContext(
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            fieldType: .multiLine
        )

        for level in CleanupLevel.allCases {
            let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: level)
            XCTAssertFalse(
                prompt.contains("single-line"),
                "\(level.displayName) prompt should NOT include single-line constraint for multiLine"
            )
        }
    }

    // MARK: - All Prompts End with Output Instruction

    func testAllPromptsEndWithOutputInstruction() {
        let context = InsertionContext.unknown

        for level in CleanupLevel.allCases {
            let prompt = LocalLLMProcessor.buildSystemPrompt(for: context, cleanupLevel: level)
            XCTAssert(
                prompt.contains("Output ONLY the cleaned text"),
                "\(level.displayName) prompt should end with output instruction"
            )
        }
    }

    // MARK: - NoOpProcessor Ignores CleanupLevel

    func testNoOpProcessorReturnsInputUnchanged() async throws {
        let processor = NoOpProcessor()
        let input = "um so like hello world"
        let context = InsertionContext.unknown

        for level in CleanupLevel.allCases {
            let output = try await processor.process(rawText: input, context: context, cleanupLevel: level, scriptPreference: nil)
            XCTAssertEqual(output, input, "NoOpProcessor should return input unchanged at \(level.displayName)")
        }
    }

    // MARK: - LLM Output Guard

    func testCorrectionFallbackDetectsFragmentCollapse() {
        XCTAssertTrue(
            LocalLLMProcessor.shouldPreferDeterministicCorrectionFallback(
                input: "can you send it to mark, oh scratch that, to john",
                output: "to john"
            )
        )
    }

    func testCorrectionFallbackAllowsCompleteRewrite() {
        XCTAssertFalse(
            LocalLLMProcessor.shouldPreferDeterministicCorrectionFallback(
                input: "go left, actually no, go right",
                output: "go right"
            )
        )
    }
}
