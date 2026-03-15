import Foundation

/// Converts spoken punctuation and symbol names to their written forms.
///
/// Runs **after** filler removal and **before** the LLM in the text
/// processing pipeline. Handles both unambiguous patterns (e.g., "question
/// mark" → "?") and context-dependent patterns (e.g., "dot" → "." only in
/// URLs/paths/emails).
///
/// This is a deterministic, zero-latency step that fixes spoken-form issues
/// that small LLMs struggle with.
struct SpokenFormNormalizer {

    /// Normalize spoken symbols in the given text.
    ///
    /// - Parameters:
    ///   - text: The text to normalize.
    ///   - unambiguousOnly: When `true`, only unambiguous patterns (e.g.,
    ///     "question mark" → "?") are applied. Context-dependent patterns
    ///     (URLs, paths, labels, commands) are skipped. Use this for
    ///     code/terminal contexts where "dot", "slash", and "dash" should
    ///     be preserved as words.
    /// - Returns: Text with spoken forms replaced by symbols where appropriate.
    static func normalize(_ text: String, unambiguousOnly: Bool = false) -> String {
        guard !text.isEmpty else { return text }

        var result = text

        if !unambiguousOnly {
            // 1. URL/email/path patterns (detect composite structure first,
            //    before individual tokens are consumed by simpler rules)
            result = normalizeURLsAndPaths(result)
        }

        // 2. Unambiguous patterns (always safe to convert, even in code/terminal)
        result = normalizeUnambiguous(result)

        // 3. Ellipsis (always safe — "dot dot dot" is never meaningful as words)
        result = normalizeEllipsis(result)

        if !unambiguousOnly {
            // 4. Colon after label words (Re:, Bug report:, Subject:, etc.)
            result = normalizeLabelColons(result)

            // 5. Command-line patterns (dash dash, dash + single char)
            result = normalizeCommandPatterns(result)
        }

        // 6. Clean up spacing around symbols
        result = cleanupSymbolSpacing(result)

        // Clean up any resulting double-spaces
        result = result.replacingOccurrences(
            of: "\\s{2,}", with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }

    // MARK: - Symbol Spacing Cleanup

    /// Remove extraneous spaces around punctuation symbols after normalization.
    ///
    /// - Removes space before: `.` `,` `?` `!` `)` `]` `:` `;` `%`
    /// - Removes space after: `(` `[` `@` `$` `#`
    /// - Removes spaces around: `_`
    /// - Collapses `$ 50` → `$50`, `@ admin` → `@admin`, etc.
    private static func cleanupSymbolSpacing(_ text: String) -> String {
        var result = text

        // Remove space before closing/trailing punctuation
        result = result.replacingOccurrences(
            of: "\\s+([.,?!);:\\]%])", with: "$1", options: .regularExpression
        )

        // Remove space after opening punctuation
        result = result.replacingOccurrences(
            of: "([(@\\[#$])\\s+", with: "$1", options: .regularExpression
        )

        // Remove spaces around underscore (joins words: "user _ name" → "user_name")
        result = result.replacingOccurrences(
            of: "\\s*_\\s*", with: "_", options: .regularExpression
        )

        return result
    }

    // MARK: - Unambiguous Patterns

    /// Patterns that are always safe to normalize regardless of context.
    private static let unambiguousPatterns: [(pattern: String, replacement: String)] = [
        ("question mark", "?"),
        ("exclamation point", "!"),
        ("exclamation mark", "!"),
        ("open parenthesis", "("),
        ("close parenthesis", ")"),
        ("open paren", "("),
        ("close paren", ")"),
        ("open bracket", "["),
        ("close bracket", "]"),
        ("underscore", "_"),
        ("ampersand", "&"),
        ("at sign", "@"),
        ("percent sign", "%"),
        ("dollar sign", "$"),
        ("equals sign", "="),
    ]

    private static func normalizeUnambiguous(_ text: String) -> String {
        var result = text
        for (spoken, written) in unambiguousPatterns {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: spoken))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: written)
        }
        return result
    }

    // MARK: - URL / Email / Path Patterns

    /// Detect and normalize composite structures: URLs, emails, file paths.
    ///
    /// Handles patterns like:
    /// - `"https colon slash slash github dot com slash aawaaz"` → `"https://github.com/aawaaz"`
    /// - `"john at example dot com"` → `"john@example.com"`
    /// - `"slash api slash v2 slash users"` → `"/api/v2/users"`
    /// - `"users slash john slash documents slash report dot pdf"` → `"users/john/documents/report.pdf"`
    private static func normalizeURLsAndPaths(_ text: String) -> String {
        var result = text

        // URL pattern: word colon slash slash (word dot)+ word (slash word)*
        // e.g. "https colon slash slash github dot com slash aawaaz"
        result = normalizeURLs(result)

        // Email pattern: word at word dot word
        // e.g. "john at example dot com" or "john dot smith at example dot com"
        result = normalizeEmails(result)

        // Path pattern: (slash word)+ possibly with dot extension
        // e.g. "slash api slash v2 slash users" or "slash users slash john slash report dot pdf"
        result = normalizePaths(result)

        // Filename/domain-like: word dot word (where word looks like a
        // filename extension, domain, or technical term — not regular prose)
        result = normalizeDottedNames(result)

        return result
    }

    /// Normalize URL patterns: `protocol colon slash slash domain (slash path)*`
    private static func normalizeURLs(_ text: String) -> String {
        // Match: protocol colon slash slash (word dot)* word (slash word)*
        let urlPattern = "\\b(https?|ftp|ssh|git)\\s+colon\\s+slash\\s+slash\\s+(\\S+(?:\\s+dot\\s+\\S+)+(?:\\s+slash\\s+\\S+)*)\\b"
        guard let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) else {
            return text
        }

        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let protocolRange = Range(match.range(at: 1), in: result),
                  let restRange = Range(match.range(at: 2), in: result) else { continue }

            let proto = String(result[protocolRange])
            var rest = String(result[restRange])

            // Convert "dot" to "." and "slash" to "/"
            rest = rest.replacingOccurrences(of: "\\s+dot\\s+", with: ".", options: .regularExpression)
            rest = rest.replacingOccurrences(of: "\\s+slash\\s+", with: "/", options: .regularExpression)

            let url = "\(proto)://\(rest)"
            result.replaceSubrange(fullRange, with: url)
        }

        return result
    }

    /// Normalize email patterns: `(word dot)* word at (word dot)+ word`
    private static func normalizeEmails(_ text: String) -> String {
        // Match: (word dot)* word at word dot word (dot word)*
        // "john dot smith at example dot com" or "john at example dot com"
        let emailPattern = "\\b((?:\\w+\\s+dot\\s+)*\\w+)\\s+at\\s+(\\w+(?:\\s+dot\\s+\\w+)+)\\b"
        guard let regex = try? NSRegularExpression(pattern: emailPattern, options: .caseInsensitive) else {
            return text
        }

        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let localRange = Range(match.range(at: 1), in: result),
                  let domainRange = Range(match.range(at: 2), in: result) else { continue }

            var local = String(result[localRange])
            var domain = String(result[domainRange])

            local = local.replacingOccurrences(of: "\\s+dot\\s+", with: ".", options: .regularExpression)
            domain = domain.replacingOccurrences(of: "\\s+dot\\s+", with: ".", options: .regularExpression)

            let email = "\(local)@\(domain)"
            result.replaceSubrange(fullRange, with: email)
        }

        return result
    }

    /// Normalize file/URL path patterns: `slash word slash word (slash word)*`
    private static func normalizePaths(_ text: String) -> String {
        // Require at least 2 "slash word" segments to avoid false positives
        // like "use slash for division". Single "slash word" is too ambiguous.
        let pathPattern = "\\bslash\\s+(\\w+(?:\\s+dot\\s+\\w+)?(?:\\s+slash\\s+\\w+(?:\\s+dot\\s+\\w+)?)+)\\b"
        guard let regex = try? NSRegularExpression(pattern: pathPattern, options: .caseInsensitive) else {
            return text
        }

        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let contentRange = Range(match.range(at: 1), in: result) else { continue }

            var content = String(result[contentRange])
            content = content.replacingOccurrences(of: "\\s+slash\\s+", with: "/", options: .regularExpression)
            content = content.replacingOccurrences(of: "\\s+dot\\s+", with: ".", options: .regularExpression)

            let path = "/\(content)"
            result.replaceSubrange(fullRange, with: path)
        }

        return result
    }

    /// File extensions and TLDs that signal "dot" should become ".".
    private static let dottedExtensions: Set<String> = [
        // File extensions
        "js", "ts", "jsx", "tsx", "py", "rb", "rs", "go", "swift", "java",
        "kt", "c", "cpp", "h", "cs", "php", "html", "css", "scss", "json",
        "xml", "yaml", "yml", "toml", "md", "txt", "pdf", "doc", "docx",
        "xls", "xlsx", "ppt", "pptx", "csv", "log", "env", "sh", "bash",
        "zsh", "fish", "conf", "cfg", "ini", "lock", "png", "jpg", "jpeg",
        "gif", "svg", "mp3", "mp4", "wav", "mov", "zip", "tar", "gz",
        // TLDs
        "com", "org", "net", "io", "dev", "app", "ai", "co", "edu", "gov",
        "me", "us", "uk",
    ]

    /// Normalize dotted names where the extension/TLD makes the intent clear.
    ///
    /// `"next dot js"` → `"next.js"`, `"report dot pdf"` → `"report.pdf"`
    /// Only triggers when the word after "dot" is a known extension/TLD.
    private static func normalizeDottedNames(_ text: String) -> String {
        let pattern = "\\b(\\w+)\\s+dot\\s+(\\w+)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }

        var result = text
        // Process in reverse to maintain valid ranges
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let nameRange = Range(match.range(at: 1), in: result),
                  let extRange = Range(match.range(at: 2), in: result) else { continue }

            let name = String(result[nameRange])
            let ext = String(result[extRange]).lowercased()

            if dottedExtensions.contains(ext) {
                let dotted = "\(name).\(result[extRange])"
                result.replaceSubrange(fullRange, with: dotted)
            }
        }

        return result
    }

    // MARK: - Label Colons

    /// Words after which "colon" becomes `:`.
    private static let labelWords: Set<String> = [
        "re", "subject", "bug", "bug report", "feature", "feature request",
        "todo", "note", "warning", "error", "info", "important",
        "from", "to", "cc", "bcc", "date", "regarding",
        "step", "example", "output", "input", "result", "summary",
        "action", "action item", "title", "description",
    ]

    /// Normalize "colon" to ":" after label words.
    ///
    /// `"re colon project update"` → `"Re: project update"`
    /// `"bug report colon app crashes"` → `"Bug report: app crashes"`
    private static func normalizeLabelColons(_ text: String) -> String {
        // Match: (label word(s)) colon
        let pattern = "\\b(\\w+(?:\\s+\\w+)?)\\s+colon\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }

        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let labelRange = Range(match.range(at: 1), in: result) else { continue }

            let label = String(result[labelRange])
            if labelWords.contains(label.lowercased()) {
                let capitalizedLabel = label.prefix(1).uppercased() + label.dropFirst()
                let replacement = "\(capitalizedLabel):"
                result.replaceSubrange(fullRange, with: replacement)
            }
        }

        return result
    }

    // MARK: - Command-Line Patterns

    /// Normalize command-line dash patterns.
    ///
    /// `"dash dash force"` → `"--force"`
    /// `"dash n"` → `"-n"` (single letter flags)
    private static func normalizeCommandPatterns(_ text: String) -> String {
        var result = text

        // Double dash: "dash dash word" → "--word"
        let doubleDashPattern = "\\bdash\\s+dash\\s+(\\w+)\\b"
        if let regex = try? NSRegularExpression(pattern: doubleDashPattern, options: .caseInsensitive) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "--$1")
        }

        // Single dash before single char: "dash n" → "-n"
        let singleDashPattern = "\\bdash\\s+([a-zA-Z])\\b"
        if let regex = try? NSRegularExpression(pattern: singleDashPattern, options: .caseInsensitive) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "-$1")
        }

        return result
    }

    // MARK: - Ellipsis

    /// Normalize "dot dot dot" to "…" or "...".
    private static func normalizeEllipsis(_ text: String) -> String {
        var result = text
        let pattern = "\\bdot\\s+dot\\s+dot\\b"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "...")
        }
        return result
    }
}
