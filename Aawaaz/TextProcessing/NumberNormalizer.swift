import Foundation

/// Converts spoken number words into digit form.
///
/// Runs as part of the deterministic pre-LLM text processing pipeline.
/// Handles cardinal numbers ("one hundred twenty three" → "123"),
/// ordinals ("twenty first" → "21st"), and decimals ("three point one four"
/// → "3.14").
///
/// This is a zero-latency, deterministic step that fixes spoken-number
/// issues that small LLMs struggle with.
struct NumberNormalizer {

    /// Normalize spoken numbers in the given text.
    ///
    /// - Parameter text: The text to normalize.
    /// - Returns: Text with spoken number words replaced by digits.
    static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return text }

        var result: [String] = []
        var i = 0

        while i < words.count {
            let (consumed, replacement) = tryConsumeNumber(words: words, startIndex: i)
            if consumed > 0 {
                result.append(replacement)
                i += consumed
            } else {
                result.append(words[i])
                i += 1
            }
        }

        return result.joined(separator: " ")
    }

    // MARK: - Number Word Lookups

    private static let ones: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19,
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let multipliers: [String: Int] = [
        "hundred": 100, "thousand": 1_000,
        "million": 1_000_000, "billion": 1_000_000_000,
    ]

    /// Ordinal words that terminate a number sequence and map to a value + suffix.
    private static let ordinalOnes: [String: (value: Int, suffix: String)] = [
        "first": (1, "st"), "second": (2, "nd"), "third": (3, "rd"),
        "fourth": (4, "th"), "fifth": (5, "th"), "sixth": (6, "th"),
        "seventh": (7, "th"), "eighth": (8, "th"), "ninth": (9, "th"),
        "tenth": (10, "th"), "eleventh": (11, "th"), "twelfth": (12, "th"),
        "thirteenth": (13, "th"), "fourteenth": (14, "th"),
        "fifteenth": (15, "th"), "sixteenth": (16, "th"),
        "seventeenth": (17, "th"), "eighteenth": (18, "th"),
        "nineteenth": (19, "th"),
    ]

    private static let ordinalTens: [String: (value: Int, suffix: String)] = [
        "twentieth": (20, "th"), "thirtieth": (30, "th"),
        "fortieth": (40, "th"), "fiftieth": (50, "th"),
        "sixtieth": (60, "th"), "seventieth": (70, "th"),
        "eightieth": (80, "th"), "ninetieth": (90, "th"),
    ]

    private static let ordinalMultipliers: [String: (value: Int, suffix: String)] = [
        "hundredth": (100, "th"), "thousandth": (1_000, "th"),
    ]

    // MARK: - Number Consumption

    /// Try to consume a number sequence starting at `startIndex`.
    ///
    /// Returns `(wordsConsumed, replacement)`. If no number is found,
    /// returns `(0, "")`.
    private static func tryConsumeNumber(words: [String], startIndex: Int) -> (Int, String) {
        var i = startIndex
        var total = 0
        var current = 0 // accumulates below the current multiplier level
        var consumed = 0
        var isOrdinal = false
        var ordinalSuffix = ""
        var hasDecimal = false
        var decimalDigits: [Int] = []
        var hasNumberWord = false
        var lastWasBarOnes = false // true when current holds a ones value with no multiplier after it

        while i < words.count {
            let word = words[i].lowercased()

            // Skip "and" between number words (only if we've already started)
            if word == "and" && hasNumberWord {
                i += 1
                consumed += 1
                continue
            }

            // Handle "a" before a multiplier: "a hundred", "a thousand"
            if word == "a" && hasNumberWord == false {
                if i + 1 < words.count {
                    let next = words[i + 1].lowercased()
                    if multipliers[next] != nil {
                        current = 1
                        hasNumberWord = true
                        i += 1
                        consumed += 1
                        continue
                    }
                }
                // Isolated "a" — not a number
                break
            }

            // Decimal handling: after "point", collect individual digits
            if word == "point" && hasNumberWord && !hasDecimal {
                hasDecimal = true
                i += 1
                consumed += 1
                // Collect digit words after point
                while i < words.count {
                    let dw = words[i].lowercased()
                    if let val = ones[dw], val <= 9 {
                        decimalDigits.append(val)
                        i += 1
                        consumed += 1
                    } else {
                        break
                    }
                }
                // If no digits after point, it wasn't a decimal
                if decimalDigits.isEmpty {
                    hasDecimal = false
                    consumed -= 1
                    i -= 1
                }
                break
            }

            // Check ordinal multipliers: "hundredth", "thousandth"
            if let ord = ordinalMultipliers[word] {
                if current == 0 { current = 1 }
                total += current * ord.value
                current = 0
                isOrdinal = true
                ordinalSuffix = ord.suffix
                hasNumberWord = true
                consumed += 1
                i += 1
                break
            }

            // Check ordinal tens: "twentieth", "thirtieth", etc.
            // Same grammar rule: ones cannot precede ordinal tens.
            if let ord = ordinalTens[word] {
                if lastWasBarOnes { break }
                current += ord.value
                isOrdinal = true
                ordinalSuffix = ord.suffix
                hasNumberWord = true
                consumed += 1
                i += 1
                break
            }

            // Check ordinal ones: "first", "second", etc.
            if let ord = ordinalOnes[word] {
                current += ord.value
                isOrdinal = true
                ordinalSuffix = ord.suffix
                hasNumberWord = true
                consumed += 1
                i += 1
                break
            }

            // Check multipliers: hundred, thousand, million, billion
            if let mult = multipliers[word] {
                if current == 0 { current = 1 }
                if mult >= 1_000 {
                    // For thousand/million/billion: fold everything accumulated
                    // into total. "two hundred thousand" = (200) * 1000.
                    total = (total + current) * mult
                    current = 0
                } else {
                    // For hundred: multiply current group only
                    current *= mult
                }
                hasNumberWord = true
                lastWasBarOnes = false
                consumed += 1
                i += 1
                continue
            }

            // Check tens
            // In English, ones cannot precede tens without a multiplier.
            // "thirty two" = 32 ✓, but "two thirty" is ambiguous (time? 230?).
            // Stop consuming so each part converts independently and the LLM
            // can interpret the relationship from context.
            if let val = tens[word] {
                if lastWasBarOnes { break }
                current += val
                hasNumberWord = true
                lastWasBarOnes = false
                consumed += 1
                i += 1
                continue
            }

            // Check ones
            if let val = ones[word] {
                current += val
                hasNumberWord = true
                lastWasBarOnes = true
                consumed += 1
                i += 1
                continue
            }

            // Not a number word — stop consuming
            break
        }

        guard hasNumberWord else { return (0, "") }

        // Finalize: trailing "and" should not be consumed (back it off)
        while consumed > 0 {
            let lastConsumedWord = words[startIndex + consumed - 1].lowercased()
            if lastConsumedWord == "and" {
                consumed -= 1
            } else {
                break
            }
        }

        guard consumed > 0 else { return (0, "") }

        total += current

        if hasDecimal {
            let decimalStr = decimalDigits.map { String($0) }.joined()
            let replacement = "\(total).\(decimalStr)"
            return (consumed, replacement)
        }

        if isOrdinal {
            return (consumed, "\(total)\(ordinalSuffix)")
        }

        return (consumed, "\(total)")
    }

}
