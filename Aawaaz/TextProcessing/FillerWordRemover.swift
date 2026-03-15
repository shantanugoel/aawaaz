import Foundation

/// Removes filler words from transcribed text using word-boundary-aware regex.
///
/// Handles both single-word fillers ("um", "uh") and multi-word phrases
/// ("you know"). Cleans up leftover double spaces, orphaned commas, and
/// leading/trailing whitespace after removal.
///
/// Context-sensitive fillers like "you know" are guarded: when preceded by
/// an auxiliary verb (e.g., "do", "did", "if"), they're kept because
/// they function as a verb phrase, not a filler.
struct FillerWordRemover {

    /// Filler phrases that can also function as meaningful verb phrases
    /// depending on the preceding word. Maps filler phrase (lowercased) to
    /// the set of preceding words that indicate a verb phrase (keep it).
    ///
    /// Example: "Do you know where it is?" → preceded by "do" → keep.
    ///          "I was, you know, going to the store" → preceded by "was" → remove.
    static let guardedFillers: [String: Set<String>] = [
        "you know": [
            "do", "did", "didn't", "don't", "doesn't",
            "if", "whether", "that",
            "could", "would", "should", "can", "will", "might", "may",
            "won't", "couldn't", "wouldn't", "shouldn't", "shall",
        ],
    ]

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

            if let guardWords = Self.guardedFillers[filler.lowercased()] {
                result = removeWithGuards(from: result, regex: regex, guardWords: guardWords)
            } else {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            }
        }

        return cleanUp(result)
    }

    // MARK: - Context-Sensitive Removal

    /// Remove filler matches only when NOT preceded by a guard word.
    ///
    /// Finds all regex matches, checks the word immediately before each one,
    /// and skips removal if that word is in the guard set.
    private func removeWithGuards(
        from text: String,
        regex: NSRegularExpression,
        guardWords: Set<String>
    ) -> String {
        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: fullRange)

        guard !matches.isEmpty else { return text }

        // Collect ranges to remove (skip guarded matches)
        var rangesToRemove: [Range<String.Index>] = []
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }

            let prefix = text[text.startIndex..<matchRange.lowerBound]
            let precedingWord = prefix
                .split(whereSeparator: \.isWhitespace)
                .last
                .map { String($0).lowercased().trimmingCharacters(in: .punctuationCharacters) }

            if let word = precedingWord, guardWords.contains(word) {
                continue
            }

            rangesToRemove.append(matchRange)
        }

        guard !rangesToRemove.isEmpty else { return text }

        // Build result by copying everything except removed ranges
        var result = ""
        var cursor = text.startIndex
        for range in rangesToRemove {
            result += text[cursor..<range.lowerBound]
            cursor = range.upperBound
        }
        result += text[cursor..<text.endIndex]

        return result
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
