/// One thing a live-preview renderer should do to a single `SyntaxElement`'s span of source text
/// instead of showing it verbatim.
public enum LivePreviewSpan: Sendable, Equatable {
    /// Hide this literal marker text (a `##`, `**`, `` ` ``, `> `, list bullet, …). The content it
    /// wraps, if any, stays visible and styled exactly as `MarkdownStyler` already renders it —
    /// only the marker range itself is elided from the display text.
    case hiddenMarker(TextRange)

    /// Replace this element's *entire* range (markers and content together) with one inline
    /// rendered representation — inline math, or a single-line `$$display$$` block. Single
    /// paragraph, single line: the replacement can sit inside that one line's display text
    /// alongside any surrounding prose.
    case renderedInline(SyntaxElement)

    /// Replace this element's *entire* range with one rendered block image — a table, a Mermaid
    /// diagram, or a multi-line `$$display$$` block. Unlike `renderedInline`, this element's
    /// source range spans more than one line, so the app-target renderer collapses it across
    /// multiple display paragraphs rather than one — see the app target's `LivePreviewController`
    /// for how the first line carries the image and subsequent lines collapse to near-zero height.
    case renderedBlock(SyntaxElement)
}

/// Computes what a live-preview display transform should do with `elements` given where the
/// cursor currently is, as a flat, order-independent list of `LivePreviewSpan`s.
///
/// Pure and stateless — safe to recompute on every keystroke and every cursor move, exactly like
/// `syntaxMap(of:)` itself. This function does not touch source text beyond what's needed to find
/// line boundaries (`DocumentLines`); building the actual display string/attachments from the
/// spans it returns is the app target's job (it needs `NSAttributedString`/`NSTextAttachment`,
/// neither of which this package depends on).
///
/// ## Reveal rule: per line (Obsidian's Live Preview model)
///
/// "The cursor's line reveals its markers" is interpreted at the *marker* granularity, not the
/// whole element: a marker range is hidden unless it overlaps the cursor's current source line.
/// This matters most for multi-line constructs — a block quote's `> ` repeats once per line (see
/// `SyntaxElement.markerRanges`), and a cursor on line 3 of a 5-line quote reveals only line 3's
/// `>`, not the other four (this falls out of the same per-marker overlap test as every other
/// kind — block quote needs no special-casing here). A fenced code/diagram block's opening and
/// closing fences are on different lines for the same reason: the cursor has to actually be on the
/// fence line to see it.
///
/// The render/no-render decision (table, Mermaid, math) uses the same "cursor anywhere on this
/// line" rule — for a multi-line block, "any line the block occupies"; for a single-line inline
/// replacement (inline math, or a `$$...$$` written on one line), just that one line. Consistently
/// line-scoped, matching the marker-reveal rule above rather than introducing a second, finer-
/// grained rule just for these four kinds.
///
/// - Parameters:
///   - source: The document text `elements` was parsed from (`syntaxMap(of: source)`); used only
///     to find line boundaries via `DocumentLines`.
///   - elements: The syntax map to render.
///   - cursorSourceOffset: The cursor's current UTF-16 offset into `source`, or `nil` if hiding is
///     disabled entirely (in which case this function returns an empty list — nothing hidden,
///     nothing rendered, plain styled source).
public func livePreviewSpans(source: String, elements: [SyntaxElement], cursorSourceOffset: Int?) -> [LivePreviewSpan] {
    guard let cursorSourceOffset else { return [] }

    let lines = DocumentLines(source)
    let clampedCursor = min(max(cursorSourceOffset, 0), source.utf16.count)
    guard let cursorLineIndex = lines.lineIndex(atUTF16Offset: clampedCursor) else { return [] }
    let cursorLineRange = lines.lineRanges[cursorLineIndex]

    func overlaps(_ range: TextRange) -> Bool {
        range.lowerBound < cursorLineRange.upperBound && range.upperBound > cursorLineRange.lowerBound
    }
    /// "Cursor anywhere on a line this element occupies" — a half-open-range overlap test would
    /// wrongly exclude a marker/element ending exactly at the cursor line's start (or starting
    /// exactly at its end); using `<=`/`>=` against the *line's* bounds (rather than `overlaps`,
    /// which is deliberately strict for marker-vs-marker adjacency) means an element merely
    /// touching the cursor's line still counts as "the cursor is on it".
    func spansLine(_ range: TextRange, lineIndex: Int) -> Bool {
        guard lineIndex >= 0, lineIndex < lines.lineRanges.count else { return false }
        let lineRange = lines.lineRanges[lineIndex]
        return range.lowerBound <= lineRange.upperBound && range.upperBound >= lineRange.lowerBound
    }
    func hasCursor(in range: TextRange) -> Bool {
        spansLine(range, lineIndex: cursorLineIndex)
    }
    func isMultiline(_ range: TextRange) -> Bool {
        guard let startLine = lines.lineIndex(atUTF16Offset: range.lowerBound) else { return false }
        let endOffset = max(range.lowerBound, range.upperBound - 1)
        guard let endLine = lines.lineIndex(atUTF16Offset: endOffset) else { return false }
        return endLine > startLine
    }

    var spans: [LivePreviewSpan] = []

    for element in elements {
        switch element.kind {
        case .table, .diagramBlock:
            if !hasCursor(in: element.range) {
                spans.append(.renderedBlock(element))
            }

        case .displayMath:
            if !hasCursor(in: element.range) {
                spans.append(isMultiline(element.range) ? .renderedBlock(element) : .renderedInline(element))
            }

        case .inlineMath:
            if !hasCursor(in: element.range) {
                spans.append(.renderedInline(element))
            }

        case .codeBlock, .thematicBreak:
            // Deliberately untouched — out of the hiding feature's stated scope. An ordinary
            // fenced code block's markers stay visible exactly as `MarkdownStyler` already shows
            // them (its fences are the reader's only cue "this is code", unlike `##`/`**`/etc.,
            // which are redundant with the styling applied to their content); a thematic break's
            // *entire* range is marker with no content to keep visible in its place, so hiding it
            // off-cursor would make the divider disappear rather than merely de-emphasize.
            break

        default:
            for marker in element.markerRanges where !overlaps(marker) {
                spans.append(.hiddenMarker(marker))
            }
        }
    }

    return spans
}
