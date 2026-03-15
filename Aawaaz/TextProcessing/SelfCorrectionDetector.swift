import Foundation

/// Detects self-correction patterns in transcribed speech and keeps only the
/// corrected version.
///
/// When a speaker says "Turn left, actually no, turn right", this detector
/// recognizes "actually no" as a correction marker and returns "turn right".
///
/// Uses a conservative repair strategy:
/// - Standalone restart phrases ("start over", "scratch that" as its own clause)
///   can discard earlier text across sentence boundaries.
/// - Inline correction phrases ("I mean", "sorry", "actually no") preserve the
///   stable prefix and replace only the corrected tail when possible.
struct SelfCorrectionDetector {

    /// A correction marker phrase with optional context requirements.
    struct Marker {
        let phrase: String
        /// When true, the marker only triggers if preceded by a comma, period,
        /// or other clause-breaking punctuation. Prevents false positives
        /// for common words like "wait" and "sorry".
        let requiresLeadingPunctuation: Bool
        /// Whether this marker can reset prior text when it appears as a
        /// standalone restart clause between sentences.
        let allowsStandaloneRestart: Bool
    }

    private struct WordToken {
        let text: String
        let lowercased: String
        let range: Range<String.Index>
    }

    /// Correction markers, ordered longest-first so multi-word markers
    /// are matched before their substrings.
    static let defaultMarkers: [Marker] = [
        Marker(phrase: "let me start over", requiresLeadingPunctuation: false, allowsStandaloneRestart: true),
        Marker(phrase: "let me rephrase", requiresLeadingPunctuation: false, allowsStandaloneRestart: true),
        Marker(phrase: "scratch that", requiresLeadingPunctuation: false, allowsStandaloneRestart: true),
        Marker(phrase: "actually no", requiresLeadingPunctuation: false, allowsStandaloneRestart: true),
        Marker(phrase: "never mind", requiresLeadingPunctuation: false, allowsStandaloneRestart: true),
        Marker(phrase: "nevermind", requiresLeadingPunctuation: false, allowsStandaloneRestart: true),
        Marker(phrase: "forget that", requiresLeadingPunctuation: false, allowsStandaloneRestart: true),
        Marker(phrase: "forget it", requiresLeadingPunctuation: false, allowsStandaloneRestart: true),
        Marker(phrase: "start over", requiresLeadingPunctuation: false, allowsStandaloneRestart: true),
        Marker(phrase: "no no no", requiresLeadingPunctuation: false, allowsStandaloneRestart: true),
        Marker(phrase: "no no", requiresLeadingPunctuation: false, allowsStandaloneRestart: true),
        Marker(phrase: "I mean", requiresLeadingPunctuation: true, allowsStandaloneRestart: false),
        Marker(phrase: "sorry", requiresLeadingPunctuation: true, allowsStandaloneRestart: false),
        Marker(phrase: "wait", requiresLeadingPunctuation: true, allowsStandaloneRestart: false),
    ]

    private static let standaloneLeadInWords: Set<String> = [
        "oh", "uh", "um", "erm", "well", "so", "sorry",
    ]

    private static let trailingLeadInWords: Set<String> = [
        "oh", "uh", "um", "erm", "well", "so", "sorry",
    ]

    private static let repairLeadInWords: Set<String> = [
        "oh", "uh", "um", "erm", "well", "so",
    ]

    private static let fragmentLeadTokens: Set<String> = [
        "to", "for", "with", "at", "in", "on", "from", "into", "onto", "about",
        "of", "the", "a", "an", "this", "that", "these", "those",
        "my", "your", "his", "her", "our", "their", "its",
        "next", "last",
    ]

    private static let fullClauseStarters: Set<String> = [
        "i", "i'm", "i've", "i'd", "i'll",
        "it", "it's",
        "we", "we're", "we've", "we'd", "we'll",
        "you", "you're", "you've", "you'd", "you'll",
        "he", "he's", "she", "she's", "they", "they're",
        "there", "here", "let's", "please",
    ]

    /// Idiomatic correction lead-ins that speakers use when correcting a value.
    /// "make it monday" means "replace with monday", not "make it monday" literally.
    private static let correctionIdioms: [[String]] = [
        ["make", "it"],
        ["make", "that"],
    ]

    private static let boundaryTokens: Set<String> = [
        "to", "for", "with", "at", "in", "on", "from", "into", "onto", "about",
        "of", "the", "a", "an", "this", "that", "these", "those",
        "my", "your", "his", "her", "our", "their", "its",
        "is", "are", "was", "were", "am", "be", "been",
    ]

    /// Function words (prepositions, articles) that are weak overlap signals.
    /// Single-token overlap on these requires structural support (copula before).
    private static let weakOverlapTokens: Set<String> = [
        "a", "an", "the", "at", "on", "in", "to", "for", "from", "with", "of", "by",
    ]

    /// Copula verbs used to validate weak-token overlaps.
    private static let copulaTokens: Set<String> = [
        "is", "are", "was", "were", "am", "be", "been",
    ]

    /// Detect and resolve self-corrections in the input text.
    ///
    /// Two-phase approach:
    /// 1. **Standalone restarts**: Markers like "scratch that" and
    ///    "actually no" discard earlier text only when they act as their own
    ///    restart clause across sentence boundaries.
    /// 2. **Inline repairs**: Markers inside a sentence preserve stable prefix
    ///    where possible and replace only the corrected tail.
    ///
    /// - Parameter text: The transcription text to process.
    /// - Returns: Text with self-corrections resolved.
    func detectAndResolve(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // Phase 1: Only standalone restart clauses can discard prior text
        // across sentence boundaries.
        let afterStandaloneRestarts = resolveStandaloneRestarts(text)

        // Phase 2: Per-sentence scope — inline markers preserve the stable
        // prefix whenever possible.
        let sentences = splitIntoSentences(afterStandaloneRestarts)
        let processed = sentences.map { resolveSentence($0) }
        let result = processed.joined(separator: " ")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    /// Resolve restart markers that behave like standalone "start over"
    /// clauses between sentences.
    ///
    /// Example: "Hey Mark. Oh sorry, scratch that. Hey John." → "Hey John."
    private func resolveStandaloneRestarts(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lastMarkerEnd: String.Index?

        let standaloneRestartMarkers = Self.defaultMarkers.filter(\.allowsStandaloneRestart)

        for marker in standaloneRestartMarkers {
            var searchStart = trimmed.startIndex
            while let range = trimmed.range(of: marker.phrase,
                                            options: .caseInsensitive,
                                            range: searchStart..<trimmed.endIndex) {
                let isBoundaryBefore = range.lowerBound == trimmed.startIndex
                    || !trimmed[trimmed.index(before: range.lowerBound)].isLetter
                let isBoundaryAfter = range.upperBound == trimmed.endIndex
                    || !trimmed[range.upperBound].isLetter

                if isBoundaryBefore
                    && isBoundaryAfter
                    && qualifiesAsStandaloneRestart(trimmed, markerRange: range) {
                    // Skip past trailing punctuation and whitespace so we land
                    // at the start of the next meaningful content.
                    let afterMarker = skipSeparatorsAndRepairLeadIn(
                        in: trimmed,
                        from: range.upperBound
                    )

                    if lastMarkerEnd == nil || afterMarker > lastMarkerEnd! {
                        lastMarkerEnd = afterMarker
                    }
                }

                searchStart = range.upperBound
            }
        }

        guard let markerEnd = lastMarkerEnd, markerEnd < trimmed.endIndex else {
            return text
        }

        let corrected = String(trimmed[markerEnd...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !corrected.isEmpty else { return text }

        // Capitalize the first character if the original started with uppercase
        if trimmed.first?.isUppercase == true, let first = corrected.first, first.isLowercase {
            return first.uppercased() + corrected.dropFirst()
        }

        return corrected
    }

    private func qualifiesAsStandaloneRestart(
        _ text: String,
        markerRange: Range<String.Index>
    ) -> Bool {
        let sentenceStart = sentenceStartIndex(in: text, before: markerRange.lowerBound)
        let leadIn = String(text[sentenceStart..<markerRange.lowerBound])

        let wordTokens = words(in: leadIn)
        guard !wordTokens.isEmpty else { return true }

        return wordTokens.allSatisfy { Self.standaloneLeadInWords.contains($0.lowercased) }
    }

    private func sentenceStartIndex(in text: String, before index: String.Index) -> String.Index {
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            if ".!?".contains(text[previous]) {
                return text.index(after: previous)
            }
            cursor = previous
        }
        return text.startIndex
    }

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
    /// Applies the earliest valid correction repeatedly so cascading repairs are
    /// handled left-to-right:
    /// "Send it to Mark, sorry, to John, actually no, to Sarah" →
    /// "Send it to Sarah"
    private func resolveSentence(_ sentence: String) -> String {
        var working = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else { return sentence }

        var passes = 0
        while passes < 8, let match = nextMarker(in: working) {
            let before = String(working[..<match.range.lowerBound])
            let repair = String(working[match.repairStart...])
            let merged = mergeCorrection(before: before, repair: repair, originalSentence: working)

            if merged == working {
                break
            }

            working = merged
            passes += 1
        }

        return working
    }

    private func nextMarker(in sentence: String) -> (range: Range<String.Index>, repairStart: String.Index)? {
        var earliest: (range: Range<String.Index>, repairStart: String.Index)?

        for marker in Self.defaultMarkers {
            var searchStart = sentence.startIndex
            while let range = sentence.range(of: marker.phrase,
                                             options: .caseInsensitive,
                                             range: searchStart..<sentence.endIndex) {
                if isValidMarkerMatch(marker, range: range, in: sentence) {
                    let repairStart = skipSeparatorsAndRepairLeadIn(in: sentence, from: range.upperBound)
                    if repairStart < sentence.endIndex,
                       earliest == nil || range.lowerBound < earliest!.range.lowerBound {
                        earliest = (range, repairStart)
                    }
                }

                searchStart = range.upperBound
            }
        }

        return earliest
    }

    private func isValidMarkerMatch(
        _ marker: Marker,
        range: Range<String.Index>,
        in sentence: String
    ) -> Bool {
        // Verify word boundaries to avoid partial matches
        let isBoundaryBefore = range.lowerBound == sentence.startIndex
            || !sentence[sentence.index(before: range.lowerBound)].isLetter
        let isBoundaryAfter = range.upperBound == sentence.endIndex
            || !sentence[range.upperBound].isLetter

        guard isBoundaryBefore && isBoundaryAfter else { return false }

        // For context-dependent markers, require surrounding punctuation
        // to distinguish correction usage from legitimate usage.
        if marker.requiresLeadingPunctuation {
            if range.lowerBound == sentence.startIndex {
                if range.upperBound < sentence.endIndex {
                    let nextChar = sentence[range.upperBound]
                    return ",;:".contains(nextChar)
                }
                return false
            }

            let preceding = sentence[sentence.startIndex..<range.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            if let lastChar = preceding.last {
                return ",;:.!?".contains(lastChar)
            }
            return false
        }

        return true
    }

    private func mergeCorrection(before: String, repair: String, originalSentence: String) -> String {
        let stablePrefix = stripTrailingLeadIn(from: before)
        let normalizedRepair = stripLeadingRepairLeadIn(from: repair)

        guard !normalizedRepair.isEmpty else { return originalSentence }

        // Try idiom stripping: "make it monday" → "monday"
        // When an idiom was stripped, require a strong prefix anchor to avoid
        // corrupting literal imperative speech (e.g., "make it happen").
        let strippedRepair = stripCorrectionIdiom(from: normalizedRepair)
        let idiomWasStripped = strippedRepair != normalizedRepair

        if repairLooksLikeFragment(strippedRepair, before: stablePrefix, fullRepair: normalizedRepair),
           let preservedPrefix = preservedPrefix(for: stablePrefix, repair: strippedRepair, requireStrongAnchor: idiomWasStripped) {
            let stitched = stitch(prefix: preservedPrefix, repair: strippedRepair)
            return normalizedSentenceStart(stitched, basedOn: originalSentence)
        }

        // Try overlap-based merge for clause-starter repairs (e.g., "it's at four")
        if let overlapMerge = tryOverlapMerge(before: stablePrefix, repair: normalizedRepair) {
            return normalizedSentenceStart(overlapMerge, basedOn: originalSentence)
        }

        return normalizedSentenceStart(normalizedRepair, basedOn: originalSentence)
    }

    private func stripTrailingLeadIn(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = words(in: trimmed)

        guard let lastMeaningful = tokens.lastIndex(where: { !Self.trailingLeadInWords.contains($0.lowercased) }) else {
            return ""
        }

        let nextIndex: String.Index
        if lastMeaningful + 1 < tokens.count {
            nextIndex = tokens[lastMeaningful + 1].range.lowerBound
        } else {
            nextIndex = trimmed.endIndex
        }

        var candidate = String(trimmed[..<nextIndex])
        candidate = candidate.replacingOccurrences(
            of: "[\\s,;:]+$",
            with: "",
            options: .regularExpression
        )
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripLeadingRepairLeadIn(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = words(in: trimmed)
        var firstMeaningful = 0

        while firstMeaningful < tokens.count,
              Self.repairLeadInWords.contains(tokens[firstMeaningful].lowercased) {
            firstMeaningful += 1
        }

        guard firstMeaningful < tokens.count else {
            return ""
        }

        let start = tokens[firstMeaningful].range.lowerBound
        return String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip correction idiom lead-ins like "make it" / "make that".
    /// Returns the value portion if an idiom is found, otherwise the original text.
    private func stripCorrectionIdiom(from text: String) -> String {
        let tokens = words(in: text)
        for idiom in Self.correctionIdioms {
            guard tokens.count > idiom.count else { continue }
            let matches = zip(tokens.prefix(idiom.count), idiom).allSatisfy {
                $0.0.lowercased == $0.1
            }
            if matches {
                let afterIdiom = tokens[idiom.count].range.lowerBound
                let remainder = String(text[afterIdiom...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !remainder.isEmpty {
                    return remainder
                }
            }
        }
        return text
    }

    /// Returns the effective repair "head" for fragment analysis — the portion
    /// of the repair text before any subsequent correction marker. This prevents
    /// cascading markers (e.g., "wednesday, actually no, thursday") from inflating
    /// the token count used for fragment classification.
    private func effectiveRepairHead(from repair: String) -> String {
        guard let match = nextMarker(in: repair) else { return repair }
        let head = String(repair[..<match.range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[,;:]+$", with: "", options: .regularExpression)
        return head.isEmpty ? repair : head
    }

    /// Try overlap-based merge for repairs starting with a full clause starter.
    /// When the repair shares tokens with the suffix of `before`, merges at the
    /// overlap point to preserve context.
    ///
    /// Example: before = "the meeting is at three", repair = "it's at four"
    /// → skip "it's", find "at" overlap → "the meeting is at four"
    private func tryOverlapMerge(before: String, repair: String) -> String? {
        let repairTokens = words(in: repair)
        guard let first = repairTokens.first,
              Self.fullClauseStarters.contains(first.lowercased) else {
            return nil
        }

        let beforeTokens = words(in: before)
        guard !beforeTokens.isEmpty else { return nil }

        // Skip clause-starter tokens at the beginning of repair
        var repairBodyStart = 1
        while repairBodyStart < repairTokens.count,
              Self.fullClauseStarters.contains(repairTokens[repairBodyStart].lowercased) {
            repairBodyStart += 1
        }
        guard repairBodyStart < repairTokens.count else { return nil }

        let repairBodyFirstToken = repairTokens[repairBodyStart].lowercased

        // Look for the overlap token in the SUFFIX of before (last 3 tokens)
        let suffixStart = max(0, beforeTokens.count - 3)
        let beforeSuffix = beforeTokens[suffixStart...]

        for (idx, beforeToken) in beforeSuffix.enumerated() where beforeToken.lowercased == repairBodyFirstToken {
            let beforeTokenIndex = suffixStart + idx
            let beforeTailCount = beforeTokens.count - beforeTokenIndex - 1
            let repairTailCount = repairTokens.count - repairBodyStart - 1

            // Guard against false-positive overlaps: the repair tail should not
            // be longer than the before tail. E.g., "on Monday" → "on sale today"
            // has repair tail (2) > before tail (1) → spurious overlap.
            guard repairTailCount <= beforeTailCount else { continue }

            // For weak overlap tokens (prepositions, articles), require a copula
            // immediately before the overlap in `before` to ensure structural
            // similarity. E.g., "is at" is valid; "meet at" is not.
            if Self.weakOverlapTokens.contains(repairBodyFirstToken) {
                guard beforeTokenIndex > 0,
                      Self.copulaTokens.contains(beforeTokens[beforeTokenIndex - 1].lowercased) else {
                    continue
                }
            }

            // Found overlap — build merged result
            let prefix = String(before[..<beforeToken.range.upperBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tailStartIndex = repairBodyStart + 1
            guard tailStartIndex < repairTokens.count else { continue }
            let tailText = String(repair[repairTokens[tailStartIndex].range.lowerBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !tailText.isEmpty {
                return stitch(prefix: prefix, repair: tailText)
            }
        }

        return nil
    }

    private func repairLooksLikeFragment(_ repair: String, before: String, fullRepair: String? = nil) -> Bool {
        let repairTokens = words(in: repair)
        let beforeTokens = words(in: before)

        guard let first = repairTokens.first?.lowercased else {
            return false
        }

        // Full clause starters are never fragments (handled by overlap merge)
        if Self.fullClauseStarters.contains(first) {
            return false
        }

        // Single-word repair is always a fragment
        if repairTokens.count == 1 {
            return true
        }

        if Self.fragmentLeadTokens.contains(first) {
            return true
        }

        // Use effective repair head for classification when subsequent markers exist.
        // E.g., "wednesday, actually no, thursday" → effective head is "wednesday" (1 token).
        let analysisRepair = fullRepair.map { effectiveRepairHead(from: $0) } ?? repair
        let analysisTokens = (analysisRepair == repair) ? repairTokens : words(in: analysisRepair)

        if analysisTokens.count == 1 {
            return true
        }

        if let analysisFirst = analysisTokens.first?.lowercased,
           Self.fragmentLeadTokens.contains(analysisFirst) {
            return true
        }

        return beforeTokens.count >= 5 && analysisTokens.count <= 3
    }

    private func preservedPrefix(for before: String, repair: String, requireStrongAnchor: Bool = false) -> String? {
        let beforeTokens = words(in: before)
        let repairTokens = words(in: repair)

        guard let firstRepair = repairTokens.first?.lowercased,
              !beforeTokens.isEmpty else {
            return nil
        }

        if let sharedAnchor = beforeTokens.last(where: { $0.lowercased == firstRepair }) {
            return String(before[..<sharedAnchor.range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let boundary = beforeTokens.last(where: { Self.boundaryTokens.contains($0.lowercased) }) {
            return String(before[..<boundary.range.upperBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Weakest fallback: drop last token. Skip when a strong anchor is required
        // (e.g., after idiom stripping) to avoid corrupting literal speech.
        guard !requireStrongAnchor else { return nil }
        guard beforeTokens.count > 1 else { return nil }

        return String(before[..<beforeTokens.last!.range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stitch(prefix: String, repair: String) -> String {
        let trimmedPrefix = prefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[,;:]+$", with: "", options: .regularExpression)
        let trimmedRepair = repair.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedPrefix.isEmpty else { return trimmedRepair }
        guard !trimmedRepair.isEmpty else { return trimmedPrefix }

        return "\(trimmedPrefix) \(trimmedRepair)"
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
    }

    private func normalizedSentenceStart(_ text: String, basedOn original: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        if original.first?.isUppercase == true, let first = trimmed.first, first.isLowercase {
            return first.uppercased() + trimmed.dropFirst()
        }

        return trimmed
    }

    private func skipSeparatorsAndRepairLeadIn(
        in text: String,
        from start: String.Index
    ) -> String.Index {
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if ".,;:!?".contains(character) || character.isWhitespace {
                index = text.index(after: index)
            } else {
                break
            }
        }

        let remainder = String(text[index...])
        let stripped = stripLeadingRepairLeadIn(from: remainder)
        guard !stripped.isEmpty,
              let range = remainder.range(of: stripped) else {
            return index
        }

        return text.index(index, offsetBy: remainder.distance(from: remainder.startIndex, to: range.lowerBound))
    }

    private func words(in text: String) -> [WordToken] {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: "\\b[\\p{L}\\p{N}']+\\b") else {
            return []
        }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        return regex.matches(in: text, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: text) else { return nil }
            let token = String(text[tokenRange])
            return WordToken(text: token, lowercased: token.lowercased(), range: tokenRange)
        }
    }
}
