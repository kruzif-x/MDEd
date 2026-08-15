import Testing
@testable import MDEdCore

@Suite("livePreviewSpans")
struct LivePreviewPlanTests {

    private func hiddenRanges(_ spans: [LivePreviewSpan]) -> [TextRange] {
        spans.compactMap { if case .hiddenMarker(let r) = $0 { return r } else { return nil } }
    }

    // MARK: - Hiding disabled

    @Test func nilCursorHidesNothing() {
        let source = "# Heading\n"
        let elements = syntaxMap(of: source)
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: nil)
        #expect(spans.isEmpty)
    }

    // MARK: - Line-scoped reveal (Obsidian's Live Preview model)

    /// Cursor anywhere on a heading's own line reveals its `##`, even far from the marker itself.
    @Test func cursorAnywhereOnHeadingLineRevealsItsMarker() {
        let source = "## Heading text here"
        let elements = syntaxMap(of: source)
        let cursor = source.utf16.count // end of the line, far from "##"
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursor)
        let hidden = hiddenRanges(spans)
        #expect(!hidden.contains(TextRange(lowerBound: 0, upperBound: 3)))
    }

    /// The whole line reveals together: every marker on the cursor's line shows, not just the
    /// element nearest the caret — this is the defining difference from an element-scoped model.
    @Test func everyMarkerOnTheCursorsLineRevealsTogether() {
        let source = "## Some **bold** heading"
        let elements = syntaxMap(of: source)
        // Cursor inside "bold" — the entire line still reveals, including the heading's own "##".
        let cursor = "## Some **bo".utf16.count
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursor)
        let hidden = hiddenRanges(spans)

        let headingMarker = TextRange(lowerBound: 0, upperBound: 3)
        #expect(!hidden.contains(headingMarker), "the whole line reveals together, including the heading's own marker")

        guard let strong = elements.first(where: { if case .strong = $0.kind { return true } else { return false } }) else {
            Issue.record("expected a .strong element")
            return
        }
        for marker in strong.markerRanges {
            #expect(!hidden.contains(marker), "bold's markers are on the same (revealed) line")
        }
    }

    @Test func caretOnADifferentLineHidesEverythingOnThisLine() {
        let source = "## Heading\nPlain text here."
        let elements = syntaxMap(of: source)
        let cursor = source.utf16.count // end of the plain text line
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursor)
        let hidden = hiddenRanges(spans)
        #expect(hidden.contains(TextRange(lowerBound: 0, upperBound: 3)))
    }

    /// Nested emphasis inside strong (`**strong *em* strong**`): cursor anywhere on the line
    /// reveals both the inner and outer markers together — no per-element distinction.
    @Test func nestedEmphasisOnTheSameLineAllRevealTogether() {
        let source = "**strong *em* strong**"
        let elements = syntaxMap(of: source)
        let cursor = "**strong *e".utf16.count // inside "em"

        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursor)
        let hidden = hiddenRanges(spans)

        guard let strong = elements.first(where: { if case .strong = $0.kind { return true } else { return false } }),
              let emphasis = elements.first(where: { if case .emphasis = $0.kind { return true } else { return false } })
        else {
            Issue.record("expected .strong and .emphasis elements")
            return
        }
        for marker in emphasis.markerRanges {
            #expect(!hidden.contains(marker))
        }
        for marker in strong.markerRanges {
            #expect(!hidden.contains(marker), "same line as the cursor, so revealed even though the cursor is in the nested span")
        }
    }

    /// Leaving the line re-hides everything on it.
    @Test func movingCursorOffTheLineReHidesIt() {
        let source = "plain **bold** plain\nsecond line"
        let elements = syntaxMap(of: source)
        let onFirstLine = "plain **bo".utf16.count
        let onSecondLine = source.utf16.count

        let onLineSpans = hiddenRanges(livePreviewSpans(source: source, elements: elements, cursorSourceOffset: onFirstLine))
        let offLineSpans = hiddenRanges(livePreviewSpans(source: source, elements: elements, cursorSourceOffset: onSecondLine))

        guard let strong = elements.first(where: { if case .strong = $0.kind { return true } else { return false } }) else {
            Issue.record("expected .strong element")
            return
        }
        for marker in strong.markerRanges {
            #expect(!onLineSpans.contains(marker))
            #expect(offLineSpans.contains(marker))
        }
    }

    // MARK: - List items and block quotes

    @Test func listItemRevealsItsOwnBulletWhenCursorIsAnywhereOnItsLine() {
        let source = "- first item text"
        let elements = syntaxMap(of: source)
        let cursor = source.utf16.count // end of the item's text, far from the bullet
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursor)
        let hidden = hiddenRanges(spans)
        guard let listItem = elements.first(where: { if case .listItem = $0.kind { return true } else { return false } }) else {
            Issue.record("expected .listItem element")
            return
        }
        for marker in listItem.markerRanges {
            #expect(!hidden.contains(marker))
        }
    }

    /// Regression: the last item in a list can carry a *second* marker range from
    /// `SyntaxMapper.genericMarkers` (its element range absorbs a trailing newline no child
    /// claims — see `SyntaxMapTests` for other `genericMarkers` edge cases) — that range is never
    /// real marker text, so it must never be classified/substituted like index 0 is, or a stray
    /// bullet glyph is drawn after the item's own content.
    @Test func lastListItemsTrailingSecondMarkerIsNeverSubstituted() {
        let source = "before\n\n- only item\n\nafter"
        let elements = syntaxMap(of: source)
        guard let listItem = elements.first(where: { if case .listItem = $0.kind { return true } else { return false } }) else {
            Issue.record("expected .listItem element")
            return
        }
        // This fixture is only interesting if it actually reproduces the two-marker shape; if a
        // future swift-markdown version stops emitting the trailing range, this assertion (not the
        // one below) is what should start failing.
        #expect(listItem.markerRanges.count == 2, "fixture no longer reproduces the trailing-marker shape this test guards")

        let cursor = 0 // cursor on "before", far from the list entirely
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursor)

        let substitutedRanges = spans.compactMap { span -> TextRange? in
            if case .substitutedMarker(let r, _) = span { return r }
            return nil
        }
        // Only the real leading marker (index 0) may be substituted; the trailing one must fall
        // back to plain hiding (deletion), not a visible glyph.
        #expect(substitutedRanges == [listItem.markerRanges[0]])
        #expect(hiddenRanges(spans).contains(listItem.markerRanges[1]))
    }

    /// Off the cursor's line, an unordered marker is substituted (a bullet glyph standing in for
    /// the deleted `- `), never silently deleted like `hiddenMarker` would.
    @Test func unorderedListMarkerIsSubstitutedNotDeletedWhenCursorIsElsewhere() {
        let source = "- first item\nsecond line"
        let elements = syntaxMap(of: source)
        let cursor = source.utf16.count // on the second line, away from the bullet
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursor)

        guard let listItem = elements.first(where: { if case .listItem = $0.kind { return true } else { return false } }) else {
            Issue.record("expected .listItem element")
            return
        }
        let marker = listItem.markerRanges[0]
        #expect(!hiddenRanges(spans).contains(marker), "must not be deleted outright")
        let substituted = spans.contains {
            if case .substitutedMarker(let r, let glyph) = $0 { return r == marker && glyph == "• " }
            return false
        }
        #expect(substituted, "top-level bullet should substitute '• ', with a trailing separator space")
    }

    /// Nested unordered markers get a different glyph per depth, cheaply derived from
    /// `SyntaxElement.depth` — not a strict requirement, but exercised here since it "falls out
    /// cheaply" per the feature's own doc comment.
    @Test func nestedUnorderedListMarkerUsesADifferentGlyph() {
        let source = "- top\n  - nested\nplain text"
        let elements = syntaxMap(of: source)
        let cursor = source.utf16.count
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursor)

        let items = elements.filter { if case .listItem = $0.kind { return true } else { return false } }
        #expect(items.count == 2)
        let nested = items.max { $0.depth < $1.depth }!
        let marker = nested.markerRanges[0]
        let substituted = spans.contains {
            if case .substitutedMarker(let r, let glyph) = $0 { return r == marker && glyph == "◦ " }
            return false
        }
        #expect(substituted, "one level deeper should substitute '◦ ', not the top-level '• '")
    }

    /// An ordered marker's number is content, not decoration — off the cursor's line it stays
    /// exactly as-is (neither deleted nor substituted), matching how a revealed marker looks.
    @Test func orderedListMarkerIsNeitherHiddenNorSubstitutedWhenCursorIsElsewhere() {
        let source = "2. second item\nplain text"
        let elements = syntaxMap(of: source)
        let cursor = source.utf16.count
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursor)

        guard let listItem = elements.first(where: { if case .listItem = $0.kind { return true } else { return false } }) else {
            Issue.record("expected .listItem element")
            return
        }
        let marker = listItem.markerRanges[0]
        #expect(!hiddenRanges(spans).contains(marker))
        #expect(!spans.contains { if case .substitutedMarker(let r, _) = $0 { return r == marker } else { return false } })
    }

    /// A task list's checkbox substitutes a checked/unchecked glyph rather than vanishing — the
    /// completion state is information, exactly like an ordered list's number.
    @Test func taskListCheckboxSubstitutesCheckedOrUncheckedGlyph() {
        let source = "- [ ] todo\n- [x] done\nplain text"
        let elements = syntaxMap(of: source)
        let cursor = source.utf16.count
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursor)

        let items = elements.filter { if case .listItem = $0.kind { return true } else { return false } }
        #expect(items.count == 2)

        func glyph(for item: SyntaxElement) -> String? {
            let marker = item.markerRanges[0]
            for span in spans {
                if case .substitutedMarker(let r, let g) = span, r == marker { return g }
            }
            return nil
        }
        #expect(glyph(for: items[0]) == "☐ ")
        #expect(glyph(for: items[1]) == "☑ ")
    }

    /// A block quote's `>` repeats once per line; the cursor's own line reveals only its own `>`,
    /// not the whole quote — this falls out of the same per-marker/per-line overlap test used for
    /// every other kind, with no block-quote-specific code needed.
    @Test func blockQuoteRevealsOnlyTheCursorsOwnLineNotTheWholeQuote() {
        let source = "> line one\n> line two\n> line three"
        let elements = syntaxMap(of: source)
        let cursorOnLineTwo = "> line one\n> li".utf16.count

        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursorOnLineTwo)
        let hidden = hiddenRanges(spans)

        guard let quote = elements.first(where: { if case .blockQuote = $0.kind { return true } else { return false } }) else {
            Issue.record("expected .blockQuote element")
            return
        }
        #expect(quote.markerRanges.count == 3, "one marker per line")
        #expect(hidden.contains(quote.markerRanges[0]), "line one's > should stay hidden")
        #expect(!hidden.contains(quote.markerRanges[1]), "line two's > (the cursor's line) should reveal")
        #expect(hidden.contains(quote.markerRanges[2]), "line three's > should stay hidden")
    }

    // MARK: - Excluded kinds stay untouched

    @Test func codeBlockFenceNeverHidden() {
        let source = "```swift\nlet x = 1\n```"
        let elements = syntaxMap(of: source)
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: source.utf16.count)
        guard let codeBlock = elements.first(where: { if case .codeBlock = $0.kind { return true } else { return false } }) else {
            Issue.record("expected .codeBlock element")
            return
        }
        let hidden = hiddenRanges(spans)
        for marker in codeBlock.markerRanges {
            #expect(!hidden.contains(marker))
        }
    }

    @Test func thematicBreakNeverHidden() {
        let source = "above\n\n---\n\nbelow"
        let elements = syntaxMap(of: source)
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: 0)
        let hidden = hiddenRanges(spans)
        guard let hr = elements.first(where: { if case .thematicBreak = $0.kind { return true } else { return false } }) else {
            Issue.record("expected .thematicBreak element")
            return
        }
        #expect(!hidden.contains(hr.range))
    }

    // MARK: - Render / no-render (tables, math, mermaid) — line-scoped, matching marker reveal

    @Test func tableRendersAsBlockWhenCursorOutsideIt() {
        let source = "text before\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\ntext after"
        let elements = syntaxMap(of: source)
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: 0)
        let isRenderedBlock = spans.contains { if case .renderedBlock(let e) = $0, case .table = e.kind { return true } else { return false } }
        #expect(isRenderedBlock)
    }

    @Test func tableSwapsToSourceWhenCursorIsOnAnyOfItsRows() {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"
        let elements = syntaxMap(of: source)
        // Cursor on the last body row, not the header — "any row", not just the first line.
        let cursor = source.utf16.count - 2
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursor)
        let isRenderedBlock = spans.contains { if case .renderedBlock(let e) = $0, case .table = e.kind { return true } else { return false } }
        #expect(!isRenderedBlock)
    }

    @Test func mermaidBlockRendersWhenCursorOutside() {
        let source = "```mermaid\ngraph TD\nA-->B\n```"
        let elements = syntaxMap(of: source)
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: nil)
        // Hiding disabled entirely -> nothing rendered.
        #expect(spans.isEmpty)

        let spansWithCursorElsewhere = livePreviewSpans(source: source + "\nafter", elements: syntaxMap(of: source + "\nafter"), cursorSourceOffset: source.utf16.count + 3)
        let isRenderedBlock = spansWithCursorElsewhere.contains { if case .renderedBlock(let e) = $0, case .diagramBlock = e.kind { return true } else { return false } }
        #expect(isRenderedBlock)
    }

    @Test func singleLineDisplayMathRendersInlineNotAsBlock() {
        let source = "before $$x^2$$ after\nsome other line"
        let elements = syntaxMap(of: source)
        let cursorOnOtherLine = source.utf16.count
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursorOnOtherLine)
        let isInline = spans.contains { if case .renderedInline(let e) = $0, case .displayMath = e.kind { return true } else { return false } }
        #expect(isInline)
    }

    @Test func multiLineDisplayMathRendersAsBlock() {
        let source = "before\n\n$$\nx^2 + y^2 = z^2\n$$\n\nafter"
        let elements = syntaxMap(of: source)
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: 0)
        let isBlock = spans.contains { if case .renderedBlock(let e) = $0, case .displayMath = e.kind { return true } else { return false } }
        #expect(isBlock)
    }

    @Test func inlineMathRendersInlineAndSwapsToSourceWhenCursorOnItsLine() {
        let source = "the value $x + 1$ is shown\nsome other line"
        let elements = syntaxMap(of: source)
        let cursorOnOtherLine = source.utf16.count
        let outside = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursorOnOtherLine)
        #expect(outside.contains { if case .renderedInline(let e) = $0, case .inlineMath = e.kind { return true } else { return false } })

        let insideCursor = "the value $x".utf16.count
        let inside = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: insideCursor)
        #expect(!inside.contains { if case .renderedInline = $0 { return true } else { return false } })
    }

    @Test func inlineMathSwapsToSourceWhenCursorIsAnywhereOnItsLineNotJustInsideIt() {
        // Line-scoped, not element-scoped: cursor elsewhere on the *same line* (not touching the
        // math span itself) still swaps it to raw source.
        let source = "before text $x + 1$ after text"
        let elements = syntaxMap(of: source)
        let cursorFarFromMath = 2 // inside "before", nowhere near "$x + 1$"
        let spans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: cursorFarFromMath)
        #expect(!spans.contains { if case .renderedInline = $0 { return true } else { return false } })
    }
}
