/// A document's text, pre-split into lines with each line's UTF-16 range recorded — the shared
/// currency type between `MDEdCore`'s line-based diff (`diffLines(_:_:)`, which just wants
/// `[String]`) and a caller that also needs to turn a *line index* back into an `NSRange` it can
/// hand to `NSTextStorage` (to paint a diff decoration, to compute a line's rendered height, to
/// scroll a hunk into view, …).
///
/// Lines are split on `"\n"` only (not `"\r"` or `"\r\n"`) — the same "caller's choice" contract
/// `diffLines(_:_:)` itself documents: plain LF splitting is the common case for Markdown source
/// on this platform, and is what keeps a line's index here in lockstep with what a caller who
/// split the same way and fed the result to `diffLines(_:_:)` is diffing. A stray `"\r"` is left
/// as ordinary trailing content of its line rather than special-cased.
public struct DocumentLines: Sendable, Equatable {
    /// The original source text this was built from.
    public let text: String

    /// `text` split on `"\n"`, each entry excluding its trailing newline. A document with `n`
    /// newline characters has `n + 1` entries, so a trailing newline produces a final empty line
    /// — consistent with how `diffLines(_:_:)`'s own tests model a trailing-newline difference.
    public let lines: [String]

    /// The UTF-16 range of each entry in `lines`, at the same index, within `text` — excluding
    /// the newline character itself.
    public let lineRanges: [TextRange]

    public init(_ text: String) {
        self.text = text
        var lines: [String] = []
        var ranges: [TextRange] = []

        var lineStart = text.startIndex
        var utf16Offset = 0
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "\n" {
                let lineText = text[lineStart..<index]
                let length = lineText.utf16.count
                lines.append(String(lineText))
                ranges.append(TextRange(lowerBound: utf16Offset, upperBound: utf16Offset + length))
                utf16Offset += length + 1 // +1 for the newline itself
                let next = text.index(after: index)
                lineStart = next
                index = next
            } else {
                index = text.index(after: index)
            }
        }
        // Final line: whatever remains after the last "\n" (or the whole string if there was
        // none). Always emitted, even if empty, so a trailing newline still yields a real empty
        // last line rather than being silently dropped.
        let lastText = text[lineStart..<text.endIndex]
        let lastLength = lastText.utf16.count
        lines.append(String(lastText))
        ranges.append(TextRange(lowerBound: utf16Offset, upperBound: utf16Offset + lastLength))

        self.lines = lines
        self.lineRanges = ranges
    }

    /// The number of lines (always `lines.count`, at least 1 even for an empty document).
    public var count: Int { lines.count }

    /// The index into `lines`/`lineRanges` whose range contains `offset` (or, for `offset` sitting
    /// exactly on a line boundary, the line it starts). `nil` only if `offset` is negative or past
    /// the end of `text`.
    public func lineIndex(atUTF16Offset offset: Int) -> Int? {
        guard offset >= 0 else { return nil }
        // Binary search over lineRanges.lowerBound for the last range starting at or before
        // `offset`.
        var lo = 0
        var hi = lineRanges.count - 1
        guard hi >= 0, offset <= (lineRanges.last?.upperBound ?? 0) else { return nil }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineRanges[mid].lowerBound <= offset {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }
}
