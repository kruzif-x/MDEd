/// Converts swift-markdown's `SourceLocation` (a 1-based line number plus a 1-based **UTF-8
/// byte** column offset within that line — that is what cmark-gfm, the C parser swift-markdown
/// wraps, natively produces) into a single absolute UTF-16 offset into the whole source string.
///
/// This conversion is the crux of why `SyntaxMapper` can be trusted around non-ASCII text. Three
/// different "lengths" are in play for the same character and they are *not* interchangeable:
/// `Character` count (grapheme clusters — what `String.count` gives you), UTF-8 byte count (what
/// cmark-gfm's column actually is), and UTF-16 code unit count (what `NSTextStorage`/`NSRange`
/// need). A single emoji can be 1 grapheme cluster, 4 UTF-8 bytes, and 2 UTF-16 code units, all
/// at once; a CJK character is 1/3/1; a base character plus a combining mark can be 1 grapheme
/// cluster made of 2 Unicode scalars. Conflating any of these silently shifts every range after
/// the first non-ASCII character in the line.
///
/// The table is built once per source string in `O(n)` and answers each `SourceLocation` query
/// in `O(log n)` (to find the line) plus `O(column)` (to walk that one line's bytes) — for the
/// range counts a syntax map produces this is effectively free next to the parse itself.
struct LineOffsetTable {
    /// The content of each line (1-indexed via `lines[n - 1]`), **excluding** its line-ending
    /// characters.
    private let lines: [Substring]

    /// The absolute UTF-16 offset, into the original source string, of the first code unit of
    /// each line (1-indexed via `lineStartUTF16Offsets[n - 1]`).
    private let lineStartUTF16Offsets: [Int]

    /// The absolute UTF-16 offset of the end of the whole source string.
    let totalUTF16Length: Int

    init(_ source: String) {
        var lines: [Substring] = []
        var starts: [Int] = []

        var lineStart = source.startIndex
        var utf16Offset = 0
        var index = source.startIndex

        while index < source.endIndex {
            let scalar = source.unicodeScalars[index]
            if scalar == "\n" {
                lines.append(source[lineStart..<index])
                starts.append(utf16Offset - source[lineStart..<index].utf16.count)
                let next = source.unicodeScalars.index(after: index)
                utf16Offset += 1
                lineStart = next
                index = next
            } else if scalar == "\r" {
                lines.append(source[lineStart..<index])
                starts.append(utf16Offset - source[lineStart..<index].utf16.count)
                var next = source.unicodeScalars.index(after: index)
                utf16Offset += 1
                if next < source.endIndex, source.unicodeScalars[next] == "\n" {
                    next = source.unicodeScalars.index(after: next)
                    utf16Offset += 1
                }
                lineStart = next
                index = next
            } else {
                utf16Offset += scalar.utf16Length
                index = source.unicodeScalars.index(after: index)
            }
        }
        // Final line: whatever remains after the last line terminator (or the whole string, if
        // there were none). Always emit it, even if empty, so a document that is empty or ends
        // exactly on a line terminator still has a valid "line 1" (or trailing empty last line)
        // to look up.
        lines.append(source[lineStart..<source.endIndex])
        starts.append(utf16Offset - source[lineStart..<source.endIndex].utf16.count)

        self.lines = lines
        self.lineStartUTF16Offsets = starts
        self.totalUTF16Length = utf16Offset
    }

    /// Converts a swift-markdown `SourceLocation` to an absolute UTF-16 offset into the source
    /// string this table was built from.
    ///
    /// - Parameters:
    ///   - line: 1-based line number, as reported by `SourceLocation.line`.
    ///   - utf8Column: 1-based UTF-8 byte offset within that line, as reported by
    ///     `SourceLocation.column`.
    func utf16Offset(line: Int, utf8Column: Int) -> Int {
        guard line >= 1, line <= lines.count else {
            // Out of range: clamp rather than trap, since a syntax map is advisory data that
            // should degrade gracefully rather than crash a text view on an unexpected parser
            // quirk.
            return line < 1 ? 0 : totalUTF16Length
        }
        let lineContent = lines[line - 1]
        let byteOffset = max(0, utf8Column - 1)
        guard byteOffset > 0 else { return lineStartUTF16Offsets[line - 1] }

        let utf8View = lineContent.utf8
        guard byteOffset <= utf8View.count else {
            return lineStartUTF16Offsets[line - 1] + lineContent.utf16.count
        }
        let byteIndex = utf8View.index(utf8View.startIndex, offsetBy: byteOffset)
        let utf16Count = lineContent.utf16.distance(from: lineContent.utf16.startIndex, to: byteIndex)
        return lineStartUTF16Offsets[line - 1] + utf16Count
    }

    /// Converts a swift-markdown `SourceLocation` directly to an absolute UTF-16 offset.
    func utf16Offset(of location: SourceLocationLike) -> Int {
        utf16Offset(line: location.line, utf8Column: location.column)
    }
}

/// A minimal structural stand-in for `Markdown.SourceLocation` so `LineOffsetTable` doesn't need
/// to import the `Markdown` module itself — kept separate so this file could plausibly be reused
/// against any parser that reports 1-based (line, UTF-8-byte-column) locations, not just
/// swift-markdown.
protocol SourceLocationLike {
    var line: Int { get }
    var column: Int { get }
}

private extension Unicode.Scalar {
    /// The number of UTF-16 code units this scalar encodes to: 2 for scalars outside the Basic
    /// Multilingual Plane (i.e. anything requiring a surrogate pair — most emoji), 1 otherwise.
    var utf16Length: Int { value > 0xFFFF ? 2 : 1 }
}
