import Foundation

/// Orchestrator for the pre-LLM text processing pipeline.
///
/// Runs deterministic text cleanup steps in sequence:
/// 1. Self-correction detection (resolve speaker corrections)
/// 2. Filler word removal (remove "um", "uh", etc.)
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
    /// - Returns: Cleaned text ready for LLM processing or direct insertion.
    func process(_ rawText: String, config: TextProcessingConfig) -> String {
        var text = rawText

        // Step 1: Self-correction detection (runs first so correction markers
        // like "actually no" and "I mean" aren't prematurely removed by filler
        // word removal).
        if config.selfCorrectionEnabled {
            text = selfCorrectionDetector.detectAndResolve(text)
        }

        // Step 2: Filler word removal
        if config.fillerRemovalEnabled {
            text = fillerWordRemover.removeFillers(from: text, fillerWords: config.fillerWords)
        }

        return text
    }
}
