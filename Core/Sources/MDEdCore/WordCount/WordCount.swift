// Word-counting and reading-time logic ported from the Python reference implementation at
// `backend/word_count.py` in the `markdown-reader` project (https://github.com/petertzy — see
// the project's own `LICENSE.md`), Copyright (c) 2026 petertzy, MIT License:
//
//     Permission is hereby granted, free of charge, to any person obtaining a copy of this
//     software and associated documentation files (the "Software"), to deal in the Software
//     without restriction, including without limitation the rights to use, copy, modify, merge,
//     publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
//     to whom the Software is furnished to do so, subject to the following conditions: The above
//     copyright notice and this permission notice shall be included in all copies or substantial
//     portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//     EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
//     FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//     HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
//     CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
//     USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// This is a from-scratch Swift reimplementation (not a transliteration of Python source lines)
// that preserves the original's Markdown-stripping rules, CJK-aware tokenization, and
// reading-time rounding behavior. See the repository root `LICENSE` for the full notice.

import Foundation

/// The outcome of analyzing a Markdown document's word count and estimated reading time.
public struct WordCountResult: Sendable, Equatable {
    /// The number of words counted, after Markdown syntax has been stripped.
    public let wordCount: Int
    /// A human-readable estimate, e.g. `"3 min read"` or `"< 1 min read"`.
    public let readingTime: String

    public init(wordCount: Int, readingTime: String) {
        self.wordCount = wordCount
        self.readingTime = readingTime
    }
}

/// Word counting and reading-time estimation for Markdown text.
///
/// Ports `backend/word_count.py`'s behavior line for line in spirit (not literal regex source,
/// since Python's `re` and Swift's `Regex` are different engines, but every substitution below is
/// the direct counterpart of one in the original and runs in the same order against the same
/// intent): strip Markdown syntax down to prose, then count words with CJK characters counted
/// individually (since CJK text has no space-delimited word boundaries) rather than word-per-run.
public enum WordCount {
    /// Words-per-minute constant used for the reading-time estimate, matching the Python
    /// original's `_WPM`.
    private static let wordsPerMinute = 238

    /// Removes common Markdown syntax tokens from `text`, leaving prose suitable for word
    /// counting. Mirrors `strip_markdown` in the Python original, applying the same substitutions
    /// in the same order (order matters: e.g. images must be stripped before the plain-link
    /// pattern runs, or an image's `[alt](url)` tail would be mistaken for a link).
    public static func stripMarkdown(_ text: String) -> String {
        var result = text
        // Fenced code blocks (```...``` and ~~~...~~~), across lines.
        result = replacing(#"```[\s\S]*?```"#, in: result, with: " ")
        result = replacing(#"~~~[\s\S]*?~~~"#, in: result, with: " ")
        // Inline code.
        result = replacing("`[^`]*`", in: result, with: " ")
        // Raw HTML tags.
        result = replacing("<[^>]+>", in: result, with: " ")
        // Images: ![alt](url) — must run before the link patterns below.
        result = replacing(#"!\[[^\]]*\]\([^)]*\)"#, in: result, with: " ")
        // Inline links: [text](url) -> text
        result = replacingCapturingFirstGroup(#"\[([^\]]*)\]\([^)]*\)"#, in: result)
        // Reference-style links: [text][ref] -> text
        result = replacingCapturingFirstGroup(#"\[([^\]]*)\]\[[^\]]*\]"#, in: result)
        // ATX heading markers at the start of a line.
        result = replacing(#"(?m)^#{1,6}\s+"#, in: result, with: "")
        // Emphasis/strong delimiters (runs of 1-3 asterisks or underscores), anywhere.
        result = replacing(#"\*{1,3}|_{1,3}"#, in: result, with: "")
        // Strikethrough delimiters.
        result = replacing("~~", in: result, with: "")
        // Block quote markers at the start of a line.
        result = replacing(#"(?m)^>\s?"#, in: result, with: "")
        // Thematic breaks (a whole line of -, *, or _, 3 or more, optionally trailed by whitespace).
        result = replacing(#"(?m)^[-*_]{3,}\s*$"#, in: result, with: "")
        // Table pipes.
        result = replacing(#"\|"#, in: result, with: " ")
        // Unordered list markers at the start of a line.
        result = replacing(#"(?m)^[\s]*[-*+]\s+"#, in: result, with: "")
        // Ordered list markers at the start of a line.
        result = replacing(#"(?m)^\s*\d+\.\s+"#, in: result, with: "")
        return result
    }

    /// Counts words in `text`, treating each CJK character (Han, Hiragana, Katakana, Hangul) as
    /// its own word, since those scripts don't use spaces between words the way Latin scripts do.
    /// Mirrors `count_words` in the Python original: pad every CJK character with spaces, then
    /// split on whitespace and count the resulting tokens.
    public static func countWords(_ text: String) -> Int {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }

        var spaced = String()
        spaced.reserveCapacity(text.count)
        for character in text {
            if isCJKCharacter(character) {
                spaced.append(" ")
                spaced.append(character)
                spaced.append(" ")
            } else {
                spaced.append(character)
            }
        }
        return spaced.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Returns a human-readable reading-time estimate for `wordCount` words at
    /// `wordsPerMinute` words per minute, rounding to the nearest whole minute — ties round to
    /// the nearest *even* minute, matching Python's `round()` (banker's rounding), not the
    /// "round half away from zero" behavior `Foundation`/`Darwin` math routines default to.
    /// Mirrors `reading_time` in the Python original.
    public static func readingTime(forWordCount wordCount: Int) -> String {
        guard wordCount > 0 else { return "< 1 min read" }
        let minutes = Double(wordCount) / Double(wordsPerMinute)
        guard minutes >= 1 else { return "< 1 min read" }
        let rounded = minutes.rounded(.toNearestOrEven)
        return "\(Int(rounded)) min read"
    }

    /// Strips Markdown syntax from `markdown`, counts the remaining words, and estimates reading
    /// time — the full pipeline the Python original's API endpoint runs
    /// (`strip_markdown` → `count_words` → `reading_time`).
    public static func analyze(_ markdown: String) -> WordCountResult {
        let stripped = stripMarkdown(markdown)
        let count = countWords(stripped)
        return WordCountResult(wordCount: count, readingTime: readingTime(forWordCount: count))
    }
}

// MARK: - CJK detection

/// The Unicode scalar ranges the Python original treats as CJK: Han (including Extension A and
/// the supplementary-plane Extension B), Hiragana, Katakana, and Hangul Syllables.
private func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x4E00...0x9FFF,   // CJK Unified Ideographs
         0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
         0x20000...0x2A6DF, // CJK Unified Ideographs Extension B
         0x3040...0x309F,   // Hiragana
         0x30A0...0x30FF,   // Katakana
         0xAC00...0xD7AF:   // Hangul Syllables
        return true
    default:
        return false
    }
}

/// `true` when every scalar making up `character` is in a CJK range. Matches on whole
/// `Character`s (grapheme clusters), not raw scalars, so a CJK base character combined with a
/// following combining mark is still treated as one CJK "word" rather than being split.
private func isCJKCharacter(_ character: Character) -> Bool {
    !character.unicodeScalars.isEmpty && character.unicodeScalars.allSatisfy(isCJKScalar)
}

// MARK: - Regex helpers

private func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
    let regex = try! Regex(pattern)
    return text.replacing(regex, with: replacement)
}

/// Replaces every match of `pattern` (which must have exactly one capture group) with that
/// group's text, i.e. `\1`-style backreference replacement.
private func replacingCapturingFirstGroup(_ pattern: String, in text: String) -> String {
    let regex = try! Regex(pattern)
    return text.replacing(regex) { match in
        guard match.output.count > 1, let substring = match.output[1].substring else {
            return ""
        }
        return String(substring)
    }
}
