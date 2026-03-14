import Foundation

/// Removes filler words from transcribed text using word-boundary-aware regex.
///
/// Handles both single-word fillers ("um", "uh") and multi-word phrases
/// ("you know"). Cleans up leftover double spaces, orphaned commas, and
/// leading/trailing whitespace after removal.
struct FillerWordRemover {

    /// Remove all configured filler words from the input text.
    ///
    /// - Parameters:
    ///   - text: The raw transcription text.
    ///   - fillerWords: Words/phrases to remove. Each is matched with `\b` anchors
    ///     to prevent partial-word matches.
    /// - Returns: Cleaned text with filler words removed.
    func removeFillers(from text: String, fillerWords: [String]) -> String {
        guard !text.isEmpty, !fillerWords.isEmpty else { return text }

        var result = text

        // Sort by length descending so multi-word phrases are matched before
        // their substrings (e.g., "you know" before "you").
        let sorted = fillerWords.sorted { $0.count > $1.count }

        for filler in sorted {
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            // Case-insensitive, word-boundary match. Optional surrounding commas
            // absorb commas around parenthetical fillers ("I went, um, to...").
            let pattern = "(,\\s*)?\\b\(escaped)\\b(\\s*,)?"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        return cleanUp(result)
    }

    // MARK: - Whitespace Cleanup

    /// Collapse multiple spaces, trim, and clean up orphaned punctuation
    /// left behind after filler removal.
    private func cleanUp(_ text: String) -> String {
        var result = text

        // Collapse multiple spaces into one
        result = result.replacingOccurrences(
            of: "\\s{2,}",
            with: " ",
            options: .regularExpression
        )

        // Remove space before punctuation (". , ? !" etc.)
        result = result.replacingOccurrences(
            of: "\\s+([.,!?;:])",
            with: "$1",
            options: .regularExpression
        )

        // Remove orphaned commas at the start of text
        result = result.replacingOccurrences(
            of: "^\\s*,\\s*",
            with: "",
            options: .regularExpression
        )

        // Collapse double commas left by adjacent filler removal
        result = result.replacingOccurrences(
            of: ",\\s*,",
            with: ",",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
