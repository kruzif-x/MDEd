/// Reports, for each line of a document, whether that line sits inside a fenced code block
/// (```` ``` ```` or `~~~`).
///
/// Several line-oriented passes need this and would otherwise each reimplement it slightly
/// differently: `DocumentChunker` must not treat a blank line *inside* a fenced block as a
/// paragraph separator (it would otherwise slice a code sample in half), and
/// `MarkdownFormatting.normalize(_:)` must not trim trailing whitespace or collapse blank runs
/// inside one, where exact whitespace can be semantically significant (a diff, a Python snippet, a
/// Markdown-inside-Markdown example). This is the one shared scan both build on.
///
/// Follows CommonMark's fence-matching rule at the level of detail that matters for a line-based
/// scan: a fence opens on a line whose only non-indentation content is three or more consecutive
/// `` ` `` or `~` characters (optionally followed by an info string for a backtick fence — GFM
/// forbids a backtick info string from itself containing a backtick, so `` ` `` info strings are
/// rejected as an opener, same as CommonMark), and closes on the first later line consisting of
/// the *same* fence character, at least as long as the opener, with nothing else on the line.
/// **Not implemented**, flagged rather than silently glossed over: indentation-sensitivity (a
/// fence nested under a list item/block quote still toggles the tracker at column 0 here) and
/// closing-fence indentation limits. Both are rare in practice for the documents this editor
/// targets; a false toggle only affects chunk/normalize boundaries, never correctness of the
/// underlying text.
public enum FencedCodeTracker {

    /// `result[i]` is `true` when `lines[i]` is inside an open fence — including the opening and
    /// closing fence lines themselves, since neither is safe to treat as ordinary prose (an
    /// opening fence's info string shouldn't be mistaken for a paragraph, and a closing fence
    /// shouldn't have its trailing whitespace trimmed as if it mattered less than it might).
    public static func linesInsideFence(_ lines: [String]) -> [Bool] {
        var result = [Bool](repeating: false, count: lines.count)
        var fenceChar: Character?
        var fenceLength = 0

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let openChar = fenceChar {
                result[index] = true
                if isClosingFence(trimmed, char: openChar, minLength: fenceLength) {
                    fenceChar = nil
                    fenceLength = 0
                }
                continue
            }
            if let (char, length) = openingFence(trimmed) {
                result[index] = true
                fenceChar = char
                fenceLength = length
            }
        }
        return result
    }

    /// Recognizes an opening fence: a run of three or more `` ` `` or `~`, with — for a backtick
    /// fence only — no further backtick anywhere on the line (GFM forbids one in the info string).
    private static func openingFence(_ trimmedLine: String) -> (Character, Int)? {
        guard let first = trimmedLine.first, first == "`" || first == "~" else { return nil }
        var length = 0
        var index = trimmedLine.startIndex
        while index < trimmedLine.endIndex, trimmedLine[index] == first {
            length += 1
            index = trimmedLine.index(after: index)
        }
        guard length >= 3 else { return nil }
        if first == "`" {
            let rest = trimmedLine[index...]
            guard !rest.contains("`") else { return nil }
        }
        return (first, length)
    }

    private static func isClosingFence(_ trimmedLine: String, char: Character, minLength: Int) -> Bool {
        guard !trimmedLine.isEmpty, trimmedLine.allSatisfy({ $0 == char }) else { return false }
        return trimmedLine.count >= minLength
    }
}
