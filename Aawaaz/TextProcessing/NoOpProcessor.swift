import Foundation

/// Pass-through post-processor that returns text unchanged.
///
/// Used when post-processing is disabled in settings, or as a fallback
/// when the configured processor is unavailable (e.g., LLM model not
/// downloaded, API key not set).
struct NoOpProcessor: PostProcessor {

    func process(rawText: String, context: InsertionContext) async throws -> String {
        rawText
    }
}
