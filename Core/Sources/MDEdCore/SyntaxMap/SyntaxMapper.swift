import Markdown

extension SourceLocation: SourceLocationLike {}

private let unitBacktick: UInt16 = 0x60      // `
private let unitTilde: UInt16 = 0x7E         // ~
private let unitSpace: UInt16 = 0x20         //   (U+0020)
private let unitTab: UInt16 = 0x09           // \t
private let unitNewline: UInt16 = 0x0A       // \n
private let unitGreaterThan: UInt16 = 0x3E   // >
private let unitDollar: UInt16 = 0x24        // $

/// Parses `source` as Markdown (via swift-markdown/cmark-gfm) and returns a flattened, precise
/// map of every construct MDEdCore knows how to describe, in document order.
///
/// This is a pure function: same input, same output, no I/O, no shared mutable state — safe to
/// call from any isolation context and safe to re-run on every keystroke (see individual type
/// docs for the one-time `O(n)` table build this relies on to stay cheap).
///
/// ## What this does that swift-markdown alone doesn't
///
/// swift-markdown's `Markup.range` gives the *whole* span of an element — markers and content
/// together — in a `SourceLocation` whose `column` is a UTF-8 **byte** offset. Neither of those
/// is directly useful to a live-preview text view: it needs UTF-16 offsets (for `NSRange`), and
/// it needs the marker/content split (to know what to hide). This function supplies both, by
/// combining swift-markdown's tree with `LineOffsetTable`'s byte→UTF-16 conversion and one of two
/// strategies for finding the marker/content boundary:
///
/// - **Container elements** (heading, emphasis, strong, strikethrough, link, image, list item):
///   content is the union of the element's *children's* own ranges, and the marker(s) are
///   whatever's left over at the start/end of the element's own range. This works because
///   swift-markdown's children ranges already exclude the delimiters that introduced their
///   parent — e.g. in `**bold**`, the child `Text("bold")`'s range starts right after the
///   opening `**`, so the gap between the `Strong` element's range and its child's range *is*
///   exactly the marker. It generalizes uniformly across every container kind, including task
///   list checkboxes (`- [x] `), which show up as pure gap even though swift-markdown models the
///   checkbox as element metadata, not a child node.
/// - **Leaf elements with no children to lean on** (inline code, fenced code blocks, thematic
///   breaks): the marker is found by scanning the element's own raw source text directly (backtick
///   /tilde fence runs, `>` block quote prefixes repeated per line). See the private
///   `*Markers(...)` helpers below.
///
/// Math (`$...$`, `$$...$$`) and Mermaid diagram fences aren't part of CommonMark or GFM, so they
/// don't appear in swift-markdown's tree at all. Mermaid is detected as a `CodeBlock` whose
/// info-string language is `mermaid` (nothing special needed). Math has no such hook — it's
/// found with a dedicated raw-text scan run after the tree walk, deliberately skipping any region
/// already claimed by a code span or code block so that `` `$5` `` in code doesn't get mistaken
/// for math. See that scan's own documentation for the delimiter heuristic and its known
/// false-positive/false-negative tradeoffs.
///
/// - Complexity: `O(n)` for the parse and offset table, plus `O(n)` for the math scan; each
///   element's marker detection is `O(length of that element)`, so the whole function is `O(n)`
///   in the length of `source` for typical documents (pathological deep nesting could add a
///   log/linear factor from repeated small scans, not observed in practice for real Markdown).
public func syntaxMap(of source: String) -> [SyntaxElement] {
    let document = Document(parsing: source, options: [.disableSmartOpts])
    let offsetTable = LineOffsetTable(source)
    let units = Array(source.utf16)

    var elements: [SyntaxElement] = []
    var codeRanges: [TextRange] = []

    func textRange(_ sourceRange: SourceRange) -> TextRange {
        TextRange(
            lowerBound: offsetTable.utf16Offset(of: sourceRange.lowerBound),
            upperBound: offsetTable.utf16Offset(of: sourceRange.upperBound)
        )
    }

    func childrenContentRange(_ markup: Markup) -> TextRange? {
        var result: TextRange?
        for child in markup.children {
            guard let childSourceRange = child.range else { continue }
            let childRange = textRange(childSourceRange)
            result = result.map { $0.union(childRange) } ?? childRange
        }
        return result
    }

    func genericMarkers(elementRange: TextRange, contentRange: TextRange?) -> [TextRange] {
        guard let content = contentRange else {
            return elementRange.isEmpty ? [] : [elementRange]
        }
        var markers: [TextRange] = []
        if elementRange.lowerBound < content.lowerBound {
            markers.append(TextRange(lowerBound: elementRange.lowerBound, upperBound: content.lowerBound))
        }
        if content.upperBound < elementRange.upperBound {
            markers.append(TextRange(lowerBound: content.upperBound, upperBound: elementRange.upperBound))
        }
        return markers
    }

    func walk(_ markup: Markup, depth: Int) {
        defer {
            for child in markup.children {
                walk(child, depth: depth + 1)
            }
        }
        guard let sourceRange = markup.range else { return }
        let elementRange = textRange(sourceRange)

        switch markup {
        case let heading as Heading:
            let content = childrenContentRange(markup)
            elements.append(SyntaxElement(
                kind: .heading(level: heading.level),
                range: elementRange,
                contentRange: content,
                markerRanges: genericMarkers(elementRange: elementRange, contentRange: content),
                depth: depth
            ))

        case is Emphasis:
            let content = childrenContentRange(markup)
            elements.append(SyntaxElement(
                kind: .emphasis,
                range: elementRange,
                contentRange: content,
                markerRanges: genericMarkers(elementRange: elementRange, contentRange: content),
                depth: depth
            ))

        case is Strong:
            let content = childrenContentRange(markup)
            elements.append(SyntaxElement(
                kind: .strong,
                range: elementRange,
                contentRange: content,
                markerRanges: genericMarkers(elementRange: elementRange, contentRange: content),
                depth: depth
            ))

        case is Strikethrough:
            let content = childrenContentRange(markup)
            elements.append(SyntaxElement(
                kind: .strikethrough,
                range: elementRange,
                contentRange: content,
                markerRanges: genericMarkers(elementRange: elementRange, contentRange: content),
                depth: depth
            ))

        case let link as Link:
            let content = childrenContentRange(markup)
            elements.append(SyntaxElement(
                kind: .link(destination: link.destination),
                range: elementRange,
                contentRange: content,
                markerRanges: genericMarkers(elementRange: elementRange, contentRange: content),
                depth: depth
            ))

        case let image as Image:
            let content = childrenContentRange(markup)
            elements.append(SyntaxElement(
                kind: .image(destination: image.source),
                range: elementRange,
                contentRange: content,
                markerRanges: genericMarkers(elementRange: elementRange, contentRange: content),
                depth: depth
            ))

        case is ListItem:
            let content = childrenContentRange(markup)
            elements.append(SyntaxElement(
                kind: .listItem,
                range: elementRange,
                contentRange: content,
                markerRanges: genericMarkers(elementRange: elementRange, contentRange: content),
                depth: depth
            ))

        case is InlineCode:
            let (content, markers) = inlineCodeMarkers(elementRange: elementRange, units: units)
            elements.append(SyntaxElement(kind: .inlineCode, range: elementRange, contentRange: content, markerRanges: markers, depth: depth))
            codeRanges.append(elementRange)

        case let codeBlock as CodeBlock:
            let (kind, content, markers) = codeBlockMarkers(elementRange: elementRange, language: codeBlock.language, units: units)
            elements.append(SyntaxElement(kind: kind, range: elementRange, contentRange: content, markerRanges: markers, depth: depth))
            codeRanges.append(elementRange)

        case is ThematicBreak:
            elements.append(SyntaxElement(kind: .thematicBreak, range: elementRange, contentRange: nil, markerRanges: elementRange.isEmpty ? [] : [elementRange], depth: depth))

        case is BlockQuote:
            let content = childrenContentRange(markup)
            let markers = blockQuoteMarkerLines(elementRange: elementRange, units: units)
            elements.append(SyntaxElement(kind: .blockQuote, range: elementRange, contentRange: content, markerRanges: markers, depth: depth))

        case is Table:
            // Table cell/row/pipe structure is not decomposed into marker vs. content — the
            // whole table is reported as a single element with no distinct markers. See the
            // package README for why this is a deliberately lighter-weight treatment than the
            // other kinds.
            elements.append(SyntaxElement(kind: .table, range: elementRange, contentRange: elementRange, markerRanges: [], depth: depth))

        default:
            break
        }
    }

    walk(document, depth: 0)
    elements.append(contentsOf: scanMath(units: units, excluding: codeRanges))
    elements.sort { $0.range.lowerBound < $1.range.lowerBound }
    return elements
}

// MARK: - Leaf-element marker scanning

/// Finds the opening/closing backtick run of an inline code span by scanning its own raw text,
/// since `InlineCode` has no children to derive the split from the way container elements do.
private func inlineCodeMarkers(elementRange: TextRange, units: [UInt16]) -> (content: TextRange?, markers: [TextRange]) {
    let lower = elementRange.lowerBound
    let upper = elementRange.upperBound

    var openEnd = lower
    while openEnd < upper, units[openEnd] == unitBacktick { openEnd += 1 }

    var closeStart = upper
    while closeStart > openEnd, units[closeStart - 1] == unitBacktick { closeStart -= 1 }

    var markers: [TextRange] = []
    if openEnd > lower { markers.append(TextRange(lowerBound: lower, upperBound: openEnd)) }
    if closeStart < upper { markers.append(TextRange(lowerBound: closeStart, upperBound: upper)) }

    let content: TextRange? = openEnd < closeStart ? TextRange(lowerBound: openEnd, upperBound: closeStart) : nil
    return (content, markers)
}

/// Finds the fence markers of a code block by scanning its own raw text.
///
/// Handles fenced blocks (`` ``` `` or `~~~`, with an optional info string on the opening line)
/// fully. For an indented code block (four-space indentation, no fence characters) this returns
/// the whole range as content with **no** marker ranges — the indentation itself isn't reported
/// as a hideable marker. Indented code blocks are rare in documents actually written for a
/// live-preview editor (fenced blocks are the practical default in CommonMark/GFM authoring), so
/// this is a deliberate scope trade-off rather than an oversight; see the package README.
private func codeBlockMarkers(elementRange: TextRange, language: String?, units: [UInt16]) -> (kind: SyntaxKind, content: TextRange?, markers: [TextRange]) {
    let kind: SyntaxKind = (language?.lowercased() == "mermaid") ? .diagramBlock : .codeBlock(language: language)
    let lower = elementRange.lowerBound
    let upper = elementRange.upperBound

    var cursor = lower
    while cursor < upper, units[cursor] == unitSpace || units[cursor] == unitTab { cursor += 1 }
    guard cursor < upper, units[cursor] == unitBacktick || units[cursor] == unitTilde else {
        return (kind, elementRange.isEmpty ? nil : elementRange, [])
    }
    let fenceChar = units[cursor]

    var fenceEnd = cursor
    while fenceEnd < upper, units[fenceEnd] == fenceChar { fenceEnd += 1 }

    var openLineEnd = fenceEnd
    while openLineEnd < upper, units[openLineEnd] != unitNewline { openLineEnd += 1 }
    if openLineEnd < upper { openLineEnd += 1 } // swallow the newline itself into the opening marker
    let openMarker = TextRange(lowerBound: lower, upperBound: openLineEnd)

    guard openMarker.upperBound < upper else {
        return (kind, nil, [openMarker])
    }

    let lastLine = lastLineRange(in: TextRange(lowerBound: openMarker.upperBound, upperBound: upper), units: units)
    let trimmed = trimmedSpaces(lastLine, units: units)
    let isCloseFence = trimmed.length >= 3 && (trimmed.lowerBound..<trimmed.upperBound).allSatisfy { units[$0] == fenceChar }

    if isCloseFence {
        let contentEnd = lastLine.lowerBound
        let content: TextRange? = contentEnd > openMarker.upperBound ? TextRange(lowerBound: openMarker.upperBound, upperBound: contentEnd) : nil
        return (kind, content, [openMarker, TextRange(lowerBound: lastLine.lowerBound, upperBound: upper)])
    } else {
        let content: TextRange? = upper > openMarker.upperBound ? TextRange(lowerBound: openMarker.upperBound, upperBound: upper) : nil
        return (kind, content, [openMarker])
    }
}

/// Returns the range of the last line within `range` (i.e. after its final newline, or the whole
/// range if it contains none) — used to test whether a code block's last line is a closing fence.
private func lastLineRange(in range: TextRange, units: [UInt16]) -> TextRange {
    var end = range.upperBound
    if end > range.lowerBound, units[end - 1] == unitNewline { end -= 1 }
    var start = end
    while start > range.lowerBound, units[start - 1] != unitNewline { start -= 1 }
    return TextRange(lowerBound: start, upperBound: end)
}

private func trimmedSpaces(_ range: TextRange, units: [UInt16]) -> TextRange {
    var lower = range.lowerBound
    var upper = range.upperBound
    while lower < upper, units[lower] == unitSpace || units[lower] == unitTab { lower += 1 }
    while upper > lower, units[upper - 1] == unitSpace || units[upper - 1] == unitTab { upper -= 1 }
    return TextRange(lowerBound: lower, upperBound: upper)
}

/// Finds the `> ` (or `>`) marker on every line of a block quote's range. Unlike every other
/// kind, a block quote's marker legitimately repeats — once per line — since CommonMark requires
/// (or, for "lazy continuation" lines, permits omitting) the `>` at the start of each quoted
/// line. A line with no leading `>` (a lazy-continuation line) contributes no marker range.
private func blockQuoteMarkerLines(elementRange: TextRange, units: [UInt16]) -> [TextRange] {
    var markers: [TextRange] = []
    var lineStart = elementRange.lowerBound
    let upper = elementRange.upperBound

    while lineStart < upper {
        var cursor = lineStart
        var spacesSeen = 0
        while cursor < upper, units[cursor] == unitSpace, spacesSeen < 3 {
            cursor += 1
            spacesSeen += 1
        }
        if cursor < upper, units[cursor] == unitGreaterThan {
            var markerEnd = cursor + 1
            if markerEnd < upper, units[markerEnd] == unitSpace { markerEnd += 1 }
            markers.append(TextRange(lowerBound: lineStart, upperBound: markerEnd))
        }

        var next = lineStart
        while next < upper, units[next] != unitNewline { next += 1 }
        if next < upper { next += 1 }
        lineStart = next
    }

    return markers
}

// MARK: - Math scanning

/// Scans `units` for `$...$` (inline) and `$$...$$` (display) math spans.
///
/// Neither is part of CommonMark or GFM, so they never appear in swift-markdown's tree — this
/// scan runs entirely outside it, directly over the raw UTF-16 units, skipping any offset already
/// claimed by a code span or code block (`excluding`) so that a literal dollar sign inside
/// `` `code` `` is never mistaken for a math delimiter.
///
/// **Heuristic, by necessity.** `$` is also ordinary currency punctuation, and nothing in the
/// source distinguishes "$5 and $10" from genuine math without a convention. This follows the
/// common Pandoc/LaTeX-adjacent convention: a `$` opens math only if immediately followed by a
/// non-space, non-newline character, and closes only at a `$` immediately preceded by a
/// non-space character. That resolves "$5 and $10" correctly (no valid closing `$` — the second
/// `$` is preceded by a space) but is not a full LaTeX-aware parse; pathological inputs can still
/// fool it. Inline math does not cross a newline; display math (`$$`) may.
private func scanMath(units: [UInt16], excluding codeRanges: [TextRange]) -> [SyntaxElement] {
    func isExcluded(_ index: Int) -> Bool {
        codeRanges.contains { $0.lowerBound <= index && index < $0.upperBound }
    }

    var elements: [SyntaxElement] = []
    let n = units.count
    var i = 0
    while i < n {
        guard units[i] == unitDollar, !isExcluded(i) else {
            i += 1
            continue
        }

        if i + 1 < n, units[i + 1] == unitDollar {
            if let close = findClosingDoubleDollar(from: i + 2, units: units, excluding: codeRanges), close > i + 2 {
                let range = TextRange(lowerBound: i, upperBound: close + 2)
                let content = TextRange(lowerBound: i + 2, upperBound: close)
                elements.append(SyntaxElement(
                    kind: .displayMath,
                    range: range,
                    contentRange: content,
                    markerRanges: [TextRange(lowerBound: i, upperBound: i + 2), TextRange(lowerBound: close, upperBound: close + 2)],
                    depth: 0
                ))
                i = close + 2
                continue
            }
            i += 1
            continue
        }

        if i + 1 < n, units[i + 1] != unitSpace, units[i + 1] != unitNewline {
            if let close = findClosingSingleDollar(from: i + 1, units: units, excluding: codeRanges),
               close > i + 1, units[close - 1] != unitSpace {
                let range = TextRange(lowerBound: i, upperBound: close + 1)
                let content = TextRange(lowerBound: i + 1, upperBound: close)
                elements.append(SyntaxElement(
                    kind: .inlineMath,
                    range: range,
                    contentRange: content,
                    markerRanges: [TextRange(lowerBound: i, upperBound: i + 1), TextRange(lowerBound: close, upperBound: close + 1)],
                    depth: 0
                ))
                i = close + 1
                continue
            }
        }
        i += 1
    }
    return elements
}

private func findClosingDoubleDollar(from start: Int, units: [UInt16], excluding codeRanges: [TextRange]) -> Int? {
    var i = start
    let n = units.count
    while i + 1 < n {
        if codeRanges.contains(where: { $0.lowerBound <= i && i < $0.upperBound }) { return nil }
        if units[i] == unitDollar, units[i + 1] == unitDollar { return i }
        i += 1
    }
    return nil
}

private func findClosingSingleDollar(from start: Int, units: [UInt16], excluding codeRanges: [TextRange]) -> Int? {
    var i = start
    let n = units.count
    while i < n {
        if units[i] == unitNewline { return nil }
        if codeRanges.contains(where: { $0.lowerBound <= i && i < $0.upperBound }) { return nil }
        if units[i] == unitDollar { return i }
        i += 1
    }
    return nil
}
