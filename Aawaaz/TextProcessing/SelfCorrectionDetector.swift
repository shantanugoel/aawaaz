import Foundation

/// Detects self-correction patterns in transcribed speech and keeps only the
/// corrected version.
///
/// When a speaker says "Turn left, actually no, turn right", this detector
/// recognizes "actually no" as a correction marker and returns "turn right".
///
/// Processes the text left-to-right. When a correction marker is found,
/// everything before it (in the current sentence) is discarded and the text
/// after the marker is kept.
struct SelfCorrectionDetector {

    /// A correction marker phrase with optional context requirements.
    struct Marker {
        let phrase: String
        /// When true, the marker only triggers if preceded by a comma, period,
        /// or other clause-breaking punctuation. Prevents false positives
        /// for common words like "wait" and "sorry".
        let requiresLeadingPunctuation: Bool
    }

    /// Correction markers, ordered longest-first so multi-word markers
    /// are matched before their substrings.
    static let defaultMarkers: [Marker] = [
        Marker(phrase: "let me rephrase", requiresLeadingPunctuation: false),
        Marker(phrase: "scratch that", requiresLeadingPunctuation: false),
        Marker(phrase: "actually no", requiresLeadingPunctuation: false),
        Marker(phrase: "no no no", requiresLeadingPunctuation: false),
        Marker(phrase: "no no", requiresLeadingPunctuation: false),
        Marker(phrase: "I mean", requiresLeadingPunctuation: true),
        Marker(phrase: "sorry", requiresLeadingPunctuation: true),
        Marker(phrase: "wait", requiresLeadingPunctuation: true),
    ]

    /// Detect and resolve self-corrections in the input text.
    ///
    /// For each sentence (split on `.!?`), scans left-to-right for correction
    /// markers. When found, discards everything before the marker and keeps the
    /// text after it. Multiple corrections in a single sentence are resolved
    /// by keeping only the text after the **last** marker.
    ///
    /// - Parameter text: The transcription text to process.
    /// - Returns: Text with self-corrections resolved.
    func detectAndResolve(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // Split into sentences, process each independently, rejoin.
        let sentences = splitIntoSentences(text)
        let processed = sentences.map { resolveSentence($0) }
        let result = processed.joined(separator: " ")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    /// Split text into sentence-like chunks on `.!?` boundaries, preserving
    /// the delimiter with the preceding chunk.
    private func splitIntoSentences(_ text: String) -> [String] {
        let pattern = "(?<=[.!?])\\s+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [text]
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: fullRange)

        if matches.isEmpty {
            return [text]
        }

        var sentences: [String] = []
        var lastEnd = 0

        for match in matches {
            let range = match.range
            let sentenceRange = NSRange(location: lastEnd, length: range.location - lastEnd)
            sentences.append(nsText.substring(with: sentenceRange))
            lastEnd = range.location + range.length
        }

        if lastEnd < nsText.length {
            sentences.append(nsText.substring(from: lastEnd))
        }

        return sentences.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Resolve corrections within a single sentence.
    ///
    /// Finds the **last** correction marker in the sentence and keeps only the
    /// text after it. This handles cascading corrections like
    /// "Go left, wait, go right, actually no, go straight" → "go straight".
    private func resolveSentence(_ sentence: String) -> String {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        var lastMarkerEnd: String.Index?

        for marker in Self.defaultMarkers {
            var searchStart = trimmed.startIndex
            while let range = trimmed.range(of: marker.phrase,
                                            options: .caseInsensitive,
                                            range: searchStart..<trimmed.endIndex) {
                // Verify word boundaries to avoid partial matches
                let isBoundaryBefore = range.lowerBound == trimmed.startIndex
                    || !trimmed[trimmed.index(before: range.lowerBound)].isLetter
                let isBoundaryAfter = range.upperBound == trimmed.endIndex
                    || !trimmed[range.upperBound].isLetter

                // For context-dependent markers, require surrounding punctuation
                // to distinguish correction usage from legitimate usage.
                let meetsContextRequirement: Bool
                if marker.requiresLeadingPunctuation {
                    if range.lowerBound == trimmed.startIndex {
                        // At sentence start: require trailing comma/punctuation
                        // "Wait, go right" → correction; "Wait for me" → not a correction
                        if range.upperBound < trimmed.endIndex {
                            let nextChar = trimmed[range.upperBound]
                            meetsContextRequirement = ",;:".contains(nextChar)
                        } else {
                            meetsContextRequirement = false
                        }
                    } else {
                        let preceding = trimmed[trimmed.startIndex..<range.lowerBound]
                            .trimmingCharacters(in: .whitespaces)
                        if let lastChar = preceding.last {
                            meetsContextRequirement = ",;:.!?".contains(lastChar)
                        } else {
                            meetsContextRequirement = false
                        }
                    }
                } else {
                    meetsContextRequirement = true
                }

                if isBoundaryBefore && isBoundaryAfter && meetsContextRequirement {
                    // Skip optional comma and whitespace after the marker
                    var afterMarker = range.upperBound
                    if afterMarker < trimmed.endIndex && trimmed[afterMarker] == "," {
                        afterMarker = trimmed.index(after: afterMarker)
                    }
                    while afterMarker < trimmed.endIndex && trimmed[afterMarker] == " " {
                        afterMarker = trimmed.index(after: afterMarker)
                    }

                    if lastMarkerEnd == nil || afterMarker > lastMarkerEnd! {
                        lastMarkerEnd = afterMarker
                    }
                }

                searchStart = range.upperBound
            }
        }

        guard let markerEnd = lastMarkerEnd, markerEnd < trimmed.endIndex else {
            return sentence
        }

        let corrected = String(trimmed[markerEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // If the correction is empty (marker was at the end), keep the original
        guard !corrected.isEmpty else { return sentence }

        // Capitalize the first character if the original sentence started with uppercase
        if trimmed.first?.isUppercase == true, let first = corrected.first, first.isLowercase {
            return first.uppercased() + corrected.dropFirst()
        }

        return corrected
    }
}
