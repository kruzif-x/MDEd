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

    /// Replace this marker's on-screen text with `glyph` instead of deleting it outright — for a
    /// list marker whose visual affordance (a bullet, a checkbox) carries meaning `hiddenMarker`
    /// would destroy. Unlike `hiddenMarker`, the marker range still occupies exactly one character
    /// of display space (the app target keeps the marker's first UTF-16 unit as a stand-in for
    /// `glyph`, mirroring how `renderedInline`/`renderedBlock` keep one unit for an attachment
    /// character), rather than collapsing to zero width.
    ///
    /// Not used for an ordered list's `1.`/`2.` marker — see `livePreviewSpans`'s `.listItem` case
    /// for why the number itself is left alone (unhidden, unsubstituted) rather than routed through
    /// here.
    case substitutedMarker(TextRange, glyph: String)
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
    // Only actually read for `.listItem` markers (`classifyListMarker`), but built unconditionally
    // here since it's a cheap `O(n)` pass no more expensive than `DocumentLines(source)` above,
    // already paid on every call regardless of whether the document has any lists.
    let sourceUnits = Array(source.utf16)
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

        case .listItem:
            // A list marker's off-cursor treatment depends on what it actually is — unlike every
            // other kind, plain deletion (`hiddenMarker`) is wrong for all three shapes this can
            // take:
            //   - unordered (`- `, `* `, `+ `): substitute a bullet glyph, or the list has no
            //     visible affordance at all — it reads as an indented paragraph.
            //   - task (`- [ ] `, `- [x] `): substitute a checkbox glyph — same reasoning, plus the
            //     checked/unchecked state is information, not decoration.
            //   - ordered (`1. `, `2. `): leave the marker alone entirely (no span at all). The
            //     number is *content* a reader relies on, not redundant syntax — and it's already
            //     dimmed by `MarkdownStyler` regardless of live-preview hiding, which is exactly
            //     the "same dimmed treatment" a marker gets when the cursor reveals it.
            //
            // Only `markerRanges[0]` is ever a real bullet/number/checkbox. `genericMarkers`
            // (`SyntaxMapper`) appends a *second*, trailing range whenever a list item's own
            // element range extends past its last child's content — observed for the last item in
            // a list, where swift-markdown's range includes a trailing newline no child claims.
            // That range is never actual marker text (typically just `"\n"`), so classifying and
            // substituting it the same way as index 0 was live: it fell through to `.unordered`
            // (nothing there looks like a digit or a checkbox) and drew a stray bullet after the
            // item's last line. Anything past index 0 gets the old plain-deletion treatment
            // instead — correct for whitespace, and exactly what shipped before this substitution
            // logic existed.
            for (index, marker) in element.markerRanges.enumerated() where !overlaps(marker) {
                guard index == 0 else {
                    spans.append(.hiddenMarker(marker))
                    continue
                }
                switch classifyListMarker(text: sourceText(marker, units: sourceUnits)) {
                case .ordered:
                    continue
                case .task(let checked):
                    spans.append(.substitutedMarker(marker, glyph: checked ? "☑" : "☐"))
                case .unordered:
                    spans.append(.substitutedMarker(marker, glyph: unorderedBulletGlyph(depth: element.depth)))
                }
            }

        default:
            for marker in element.markerRanges where !overlaps(marker) {
                spans.append(.hiddenMarker(marker))
            }
        }
    }

    return spans
}

// MARK: - List marker classification

/// What kind of list marker a `.listItem`'s marker range actually is — swift-markdown's tree
/// reports every list item uniformly as `SyntaxKind.listItem` (see that case's doc comment), so
/// this is a raw-text classification of the marker itself, the same "scan the source" strategy
/// `SyntaxMapper`'s own leaf-element marker helpers use for constructs the parse tree doesn't
/// split out on its own.
private enum ListMarkerShape {
    case ordered
    case unordered
    case task(checked: Bool)
}

/// `text` is one `.listItem` marker range's raw source — `"- "`, `"12. "`, `"- [x] "`, etc. A
/// checkbox token anywhere in it (task lists are unordered in every Markdown flavor this app
/// parses, but the check is independent of the leading bullet/number regardless) wins over the
/// leading-character test, since `"- [ ] "` would otherwise misclassify as plain `.unordered`.
private func classifyListMarker(text: String) -> ListMarkerShape {
    if text.contains("[ ]") { return .task(checked: false) }
    if text.contains("[x]") || text.contains("[X]") { return .task(checked: true) }
    if let first = text.first(where: { !$0.isWhitespace }), first.isASCII, first.isNumber {
        return .ordered
    }
    return .unordered
}

/// The bullet glyph for an unordered list marker at `depth` (a `SyntaxElement.depth`, i.e. distance
/// from the document root — see that property's doc comment). Each level of list nesting adds two
/// to `depth` (a `List` container, then the `ListItem` itself), so top-level items sit at depth 2;
/// `(depth - 2) / 2` recovers a 0-based *list* nesting level from that without threading a separate
/// counter through the parse. A different glyph per level is a nice-to-have, not a correctness
/// requirement, so this degrades gracefully (clamped, cycling every three levels) rather than
/// needing to be exactly right for a pathologically deep list.
private func unorderedBulletGlyph(depth: Int) -> String {
    let level = max(0, (depth - 2) / 2)
    switch level % 3 {
    case 0: return "•"
    case 1: return "◦"
    default: return "▪"
    }
}

/// `range`'s raw text, read from `units` (the source's UTF-16 units, which a caller may already
/// have on hand) rather than re-deriving a `String` slice through `String.Index` — cheap, and
/// consistent with how `SyntaxMapper`'s own marker scanning reads source text.
private func sourceText(_ range: TextRange, units: [UInt16]) -> String {
    let lower = max(0, min(range.lowerBound, units.count))
    let upper = max(lower, min(range.upperBound, units.count))
    guard lower < upper else { return "" }
    return String(decoding: units[lower..<upper], as: UTF16.self)
}
