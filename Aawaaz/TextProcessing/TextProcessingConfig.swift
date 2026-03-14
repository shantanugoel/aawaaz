import Foundation

/// Configuration for the pre-LLM text processing pipeline.
///
/// Controls which processing steps are active and the filler word list.
/// Persisted via UserDefaults.
struct TextProcessingConfig: Equatable {

    var fillerRemovalEnabled: Bool
    var selfCorrectionEnabled: Bool
    var fillerWords: [String]

    /// Default filler words that are safe to match with word-boundary regex.
    ///
    /// Excludes words with high false-positive risk (e.g., "like" as a verb,
    /// "right" as direction/adjective, "so" as connector). Users can add those
    /// manually if they prefer more aggressive cleanup. LLM post-processing
    /// (Phase 3.3+) handles nuanced filler detection better.
    static let defaultFillerWords: [String] = [
        "um", "uh", "erm", "hmm",
        "you know", "basically", "literally",
    ]

    static let `default` = TextProcessingConfig(
        fillerRemovalEnabled: true,
        selfCorrectionEnabled: true,
        fillerWords: defaultFillerWords
    )

    // MARK: - Persistence

    private static let fillerRemovalKey = "textProcessing.fillerRemovalEnabled"
    private static let selfCorrectionKey = "textProcessing.selfCorrectionEnabled"
    private static let fillerWordsKey = "textProcessing.fillerWords"

    static func load() -> TextProcessingConfig {
        let defaults = UserDefaults.standard

        let fillerRemoval = defaults.object(forKey: fillerRemovalKey) as? Bool ?? true
        let selfCorrection = defaults.object(forKey: selfCorrectionKey) as? Bool ?? true
        let fillerWords = defaults.stringArray(forKey: fillerWordsKey) ?? defaultFillerWords

        return TextProcessingConfig(
            fillerRemovalEnabled: fillerRemoval,
            selfCorrectionEnabled: selfCorrection,
            fillerWords: fillerWords
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(fillerRemovalEnabled, forKey: Self.fillerRemovalKey)
        defaults.set(selfCorrectionEnabled, forKey: Self.selfCorrectionKey)
        defaults.set(fillerWords, forKey: Self.fillerWordsKey)
    }
}
