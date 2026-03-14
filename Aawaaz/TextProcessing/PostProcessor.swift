import Foundation

/// A post-processing step that transforms transcribed text before insertion.
///
/// Post-processors run after Whisper transcription and the deterministic
/// text cleanup pipeline (filler removal, self-correction detection).
/// They receive an ``InsertionContext`` for app-aware formatting.
///
/// Conforming types include:
/// - ``NoOpProcessor``: Pass-through (when post-processing is disabled)
/// - Future: `LocalLLMProcessor`, `RemoteLLMProcessor` (Steps 3.3–3.4)
protocol PostProcessor: Sendable {

    /// Process transcribed text using insertion context for app-aware
    /// formatting decisions.
    ///
    /// - Parameters:
    ///   - rawText: Text to process (output of the deterministic pipeline).
    ///   - context: The insertion context describing the target app and field.
    /// - Returns: Processed text ready for insertion or further processing.
    /// - Throws: If processing fails (callers should fall back to the original text).
    func process(rawText: String, context: InsertionContext) async throws -> String
}
