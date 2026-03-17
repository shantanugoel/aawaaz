import Foundation

/// Result of a single sub-stage in the deterministic text processing pipeline.
struct TextProcessingStageResult: Sendable {
    let name: String
    let enabled: Bool
    let input: String
    let output: String
    var changed: Bool { input != output }
}

/// Detailed result from `processWithDetails`, exposing per-stage transformations.
struct TextProcessingResult: Sendable {
    let output: String
    let stages: [TextProcessingStageResult]
}

/// Orchestrator for the pre-LLM text processing pipeline.
///
/// Runs deterministic text cleanup steps in sequence:
/// 1. Self-correction detection (resolve speaker corrections)
/// 2. Filler word removal (remove "um", "uh", etc.)
/// 3. Spoken-form normalization (convert "question mark" → "?", etc.)
/// 4. Number normalization (convert "twenty three" → "23", etc.)
///
/// These run **after** Whisper transcription and **before** any LLM
/// post-processing. They are fast, deterministic, and work even when
/// the LLM is disabled.
struct TextProcessor {

    private let fillerWordRemover = FillerWordRemover()
    private let selfCorrectionDetector = SelfCorrectionDetector()

    /// Run all enabled text processing steps on the raw transcription.
    ///
    /// - Parameters:
    ///   - rawText: The unprocessed Whisper output.
    ///   - config: Controls which steps are active and the filler word list.
    ///   - context: Optional insertion context. When the app is a code editor
    ///              or terminal, spoken-form normalization is skipped so that
    ///              words like "dash" and "slash" pass through to the LLM.
    /// - Returns: Cleaned text ready for LLM processing or direct insertion.
    func process(_ rawText: String, config: TextProcessingConfig, context: InsertionContext? = nil) -> String {
        processWithDetails(rawText, config: config, context: context).output
    }

    /// Run all enabled text processing steps, returning per-stage details for logging.
    func processWithDetails(_ rawText: String, config: TextProcessingConfig, context: InsertionContext? = nil) -> TextProcessingResult {
        var text = rawText
        var stages: [TextProcessingStageResult] = []

        // Step 1: Self-correction detection (runs first so correction markers
        // like "actually no" and "I mean" aren't prematurely removed by filler
        // word removal).
        let selfCorrectionInput = text
        if config.selfCorrectionEnabled {
            let beforeCorrection = text
            text = selfCorrectionDetector.detectAndResolve(text)

            // If self-correction significantly shortened the text, capitalize
            // the first character. This handles cases like "send to mark,
            // scratch that, to john" → "to john" → "To john".
            // Skip for code/terminal where identifiers should stay lowercase.
            let isCodeContext = context.map { $0.appCategory == .code || $0.appCategory == .terminal } ?? false
            if !isCodeContext {
                let beforeWords = beforeCorrection.split(whereSeparator: \.isWhitespace).count
                let afterWords = text.split(whereSeparator: \.isWhitespace).count
                if beforeWords > 0, afterWords > 0,
                   Double(afterWords) / Double(beforeWords) <= 0.5,
                   let first = text.first, first.isLowercase {
                    text = first.uppercased() + text.dropFirst()
                }
            }
        }
        stages.append(TextProcessingStageResult(
            name: "self-correction", enabled: config.selfCorrectionEnabled,
            input: selfCorrectionInput, output: text
        ))

        // Step 2: Filler word removal
        let fillerInput = text
        if config.fillerRemovalEnabled {
            text = fillerWordRemover.removeFillers(from: text, fillerWords: config.fillerWords)
        }
        stages.append(TextProcessingStageResult(
            name: "filler removal", enabled: config.fillerRemovalEnabled,
            input: fillerInput, output: text
        ))

        // Step 3: Spoken-form normalization (converts spoken symbols to written forms)
        // In code/terminal contexts, only apply unambiguous patterns (e.g.,
        // "question mark" → "?") and skip context-dependent ones (URLs, paths,
        // commands) so that "dot", "slash", "dash" pass through to the LLM.
        let normInput = text
        let isCodeTerminal = context.map { $0.appCategory == .code || $0.appCategory == .terminal } ?? false
        text = SpokenFormNormalizer.normalize(text, unambiguousOnly: isCodeTerminal)
        stages.append(TextProcessingStageResult(
            name: "spoken forms", enabled: true,
            input: normInput, output: text
        ))

        // Step 4: Number normalization (converts spoken numbers to digits)
        let numberInput = text
        text = NumberNormalizer.normalize(text)
        stages.append(TextProcessingStageResult(
            name: "number normalization", enabled: true,
            input: numberInput, output: text
        ))

        return TextProcessingResult(output: text, stages: stages)
    }
}
