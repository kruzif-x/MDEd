import Cocoa
import MDEdCore

/// Drives live-preview editing for one `EditorViewController`: hides Markdown markers except on
/// the cursor's current line, and swaps tables/math/Mermaid for rendered images except where the
/// cursor is — see the type-level doc comments on `MDEdCore.livePreviewSpans` and
/// `MDEdCore.DisplayMapper` for the pure logic this is built on. Everything *this* type does is
/// wiring that pure logic into TextKit 2's actual display machinery:
///
/// - `NSTextContentStorageDelegate.textContentStorage(_:textParagraphWith:)` returns a display
///   paragraph that differs from the backing store for exactly the paragraphs that need it (a
///   marker hidden, an attachment inserted, a collapsed-block continuation line thinned) — every
///   other paragraph gets `nil`, falling through to the content storage's own unmodified default.
/// - `BlockImageRenderer` is asked, off the main render pass, to turn a table/math/diagram element
///   into an image; when it finishes, this controller invalidates exactly that element's carrier
///   paragraph so the delegate gets asked again and picks up the now-available image.
///
/// **Never mutates text storage.** Every method here either reads `textContentStorage.textStorage`
/// or hands the delegate a freshly-built `NSTextParagraph` — nothing calls
/// `replaceCharacters(in:with:)` or any other storage-mutating API. Hiding is a display transform
/// only; the file on disk, undo stack, and `Document.currentText` never see it.
final class LivePreviewController: NSObject {

    /// Per-source-line-index (0-based, `DocumentLines`) placeholder height for a paragraph that's
    /// fully collapsed into a preceding block's rendered image — see this type's doc comment on
    /// `LineNumberGutterView.collapsedContinuationLineIndices` for why this can't be truly zero.
    private static let collapsedLineFont = NSFont.systemFont(ofSize: 0.5)
    private static let collapsedLinePlaceholder = "\u{200B}" // zero-width space

    private unowned let document: Document

    /// The most recent full recompute's inputs/outputs — rebuilt on every debounced restyle pass
    /// (a real text edit) and reused as-is by `selectionDidChange(cursorOffset:)` (cursor motion
    /// alone never invalidates the parse, only which spans are revealed).
    private var source: String = ""
    private var elements: [SyntaxElement] = []
    private var lines = DocumentLines("")
    private var cursorSourceOffset: Int = 0
    private var spans: [LivePreviewSpan] = []
    private(set) var mapper = DisplayMapper.identity(sourceLength: 0)

    /// Line indices (0-based) currently collapsed to near-zero height because they're a
    /// continuation line of a rendered block — read by `EditorViewController` to hand to
    /// `LineNumberGutterView.collapsedContinuationLineIndices`.
    private(set) var collapsedContinuationLineIndices: Set<Int> = []

    /// Images already rendered for the current plan, keyed by the element's source range (stable
    /// for the lifetime of one parse — a fresh parse after an edit invalidates this entirely, which
    /// is correct: the element at that range may no longer be the same construct).
    private var renderedImages: [MDEdCore.TextRange: NSImage] = [:]
    private var pendingRenders: Set<MDEdCore.TextRange> = []

    /// Whichever paragraphs were most recently displayed with modifications, so a redundant
    /// re-invalidation isn't needed when nothing actually changed between two calls (e.g. two
    /// selection-change notifications landing on the same line in a row).
    private var lastModifiedRanges: [NSRange] = []

    /// The text container's current available width, in points — what a `.renderedBlock` table
    /// asks `BlockImageRenderer` to render at, so it fills the editor's actual measure instead of
    /// shrink-wrapping to its content's minimum width. Kept in sync by `EditorViewController`
    /// (`containerWidthDidChange(_:)`, debounced against continuous window-resize churn); starts
    /// at a plausible default rather than `0` so the very first render (which can be requested
    /// before the view has ever been laid out — see `Document.makeWindowControllers()`) doesn't
    /// ask for a zero-width image.
    private var containerWidth: CGFloat = 600

    var onNeedsRedisplay: (() -> Void)?

    init(document: Document) {
        self.document = document
        super.init()
    }

    // MARK: - Enablement

    /// Hiding is off if the user turned it off (`EditorSettings.livePreviewEnabled`), or if this
    /// document is simultaneously open in a comparison window — see
    /// `Document.comparePaneAttachmentCount`'s doc comment for why the latter is a hard
    /// requirement, not a preference.
    private var isEnabled: Bool {
        EditorSettings.current().livePreviewEnabled && !document.hasComparePane
    }

    // MARK: - Recompute entry points

    /// Full recompute: re-parses `newSource`, rebuilds the plan against `cursorOffset`, and
    /// invalidates every paragraph whose display differs from before. Called from
    /// `EditorViewController`'s existing debounced restyle pass — sharing that debounce (rather
    /// than reparsing on every keystroke) is deliberate, matching how `MarkdownStyler.restyle`
    /// itself is debounced.
    func textDidChange(newSource: String, cursorOffset: Int) {
        source = newSource
        elements = syntaxMap(of: newSource)
        lines = DocumentLines(newSource)
        renderedImages.removeAll()
        pendingRenders.removeAll()
        recomputePlan(cursorOffset: cursorOffset, invalidateEverything: true)
    }

    /// Cheap recompute: the parse is still valid (no text changed), only which spans are revealed
    /// might have — invalidates just the paragraphs whose displayed content actually changes
    /// between the old cursor position and the new one (typically one or two paragraphs: the line
    /// the cursor left, the line/element it entered).
    func selectionDidChange(cursorOffset: Int) {
        guard cursorOffset != cursorSourceOffset else { return }
        recomputePlan(cursorOffset: cursorOffset, invalidateEverything: false)
    }

    /// The text container's available width changed (a window resize, or a Settings ▸ Measure
    /// change) — re-renders every currently-rendered block at the new width. A no-op if the width
    /// didn't actually move (guards against `EditorViewController`'s debounce still handing back
    /// the same value it last reported).
    func containerWidthDidChange(_ newWidth: CGFloat) {
        guard abs(newWidth - containerWidth) > 0.5 else { return }
        containerWidth = max(0, newWidth)
        invalidateRenderedImages()
    }

    /// The editor's effective appearance changed (Settings ▸ Theme, or the system following
    /// "System" while the OS itself switches) — re-renders every currently-rendered block so its
    /// CSS/Mermaid theme matches again.
    func appearanceDidChange() {
        invalidateRenderedImages()
    }

    /// Drops every already-rendered block image and asks for them again — used by both
    /// `containerWidthDidChange(_:)` and `appearanceDidChange()`, which both need the exact same
    /// response: what's on screen no longer reflects the current width/appearance, so it has to be
    /// treated as not-yet-rendered (falling back to the hourglass placeholder momentarily, exactly
    /// as a brand-new block does) rather than left showing a stale image. Doesn't touch `spans`,
    /// `mapper`, or anything else `recomputePlan` owns — the *plan* (what's hidden, what's
    /// rendered vs. shown as source) didn't change, only what a "rendered" block should look like.
    private func invalidateRenderedImages() {
        guard isEnabled, !renderedImages.isEmpty || !pendingRenders.isEmpty else { return }
        renderedImages.removeAll()
        pendingRenders.removeAll()
        for span in spans {
            switch span {
            case .renderedInline(let e):
                invalidateDisplay(for: lineRange(containing: e.range).nsRange)
            case .renderedBlock(let e):
                invalidateDisplay(for: MDEdCore.TextRange(lowerBound: e.range.lowerBound, upperBound: e.range.upperBound).nsRange)
            case .hiddenMarker, .substitutedMarker:
                continue
            }
        }
        kickOffPendingRenders()
    }

    private func recomputePlan(cursorOffset: Int, invalidateEverything: Bool) {
        cursorSourceOffset = cursorOffset
        let effectiveCursor: Int? = isEnabled ? cursorOffset : nil
        let newSpans = livePreviewSpans(source: source, elements: elements, cursorSourceOffset: effectiveCursor)

        let previouslyModified = Set(lastModifiedRanges.map { MDEdCore.TextRange($0.location..<($0.location + $0.length)) })
        spans = newSpans
        rebuildMapper()
        rebuildCollapsedLines()

        let newModifiedRanges = modifiedSourceRanges()
        lastModifiedRanges = newModifiedRanges.map(\.nsRange)

        if invalidateEverything {
            invalidateDisplay(for: NSRange(location: 0, length: (source as NSString).length))
        } else {
            let changed = previouslyModified.symmetricDifference(Set(newModifiedRanges))
            for range in changed {
                invalidateDisplay(for: range.nsRange)
            }
        }

        kickOffPendingRenders()
    }

    /// The union of every paragraph range whose display currently differs from its backing text —
    /// hidden markers, render carriers, and collapsed continuation lines all fall in here. Used
    /// only to compute the *diff* between two plans for targeted invalidation; the delegate method
    /// itself recomputes this same information per paragraph independently (see below).
    private func modifiedSourceRanges() -> [MDEdCore.TextRange] {
        var ranges: [MDEdCore.TextRange] = []
        for span in spans {
            switch span {
            case .hiddenMarker(let r): ranges.append(lineRange(containing: r))
            case .substitutedMarker(let r, _): ranges.append(lineRange(containing: r))
            case .renderedInline(let e): ranges.append(lineRange(containing: e.range))
            case .renderedBlock(let e): ranges.append(MDEdCore.TextRange(lowerBound: e.range.lowerBound, upperBound: e.range.upperBound))
            }
        }
        return ranges
    }

    private func lineRange(containing range: MDEdCore.TextRange) -> MDEdCore.TextRange {
        guard let idx = lines.lineIndex(atUTF16Offset: range.lowerBound) else { return range }
        return lines.lineRanges[idx]
    }

    // MARK: - DisplayMapper

    private func rebuildMapper() {
        var hidden: [MDEdCore.TextRange] = []
        for span in spans {
            switch span {
            case .hiddenMarker(let r):
                hidden.append(r)
            case .renderedInline(let e), .renderedBlock(let e):
                // Keep exactly the element's first UTF-16 unit as the display's stand-in for the
                // attachment character; hide the rest. See this file's PR notes for why this is
                // what keeps `DisplayMapper`'s length bookkeeping accurate to what TextKit 2 will
                // actually lay out (one attachment character), rather than silently under-counting
                // by one per rendered element.
                guard e.range.length > 0 else { continue }
                hidden.append(MDEdCore.TextRange(lowerBound: e.range.lowerBound + 1, upperBound: e.range.upperBound))
            case .substitutedMarker(let r, let glyph):
                // Same kept-prefix trick as above, widened from a single unit to
                // `keptUnitLength(for:markerLength:)` units — enough for `glyph` (which now
                // includes its own trailing separator space, e.g. `"• "`) to stand in as a
                // same-length replacement rather than for just its first character. The rest of
                // the marker (the raw `"- "`/`"[ ] "`/etc. text `glyph` is replacing) is hidden,
                // same as before.
                guard r.length > 0 else { continue }
                let keptLength = keptUnitLength(for: glyph, markerLength: r.length)
                hidden.append(MDEdCore.TextRange(lowerBound: r.lowerBound + keptLength, upperBound: r.upperBound))
            }
        }
        mapper = DisplayMapper(sourceLength: (source as NSString).length, hiddenRanges: hidden)
    }

    private func rebuildCollapsedLines() {
        var collapsed: Set<Int> = []
        for span in spans {
            guard case .renderedBlock(let element) = span else { continue }
            guard let firstLine = lines.lineIndex(atUTF16Offset: element.range.lowerBound) else { continue }
            let lastOffset = max(element.range.lowerBound, element.range.upperBound - 1)
            guard let lastLine = lines.lineIndex(atUTF16Offset: lastOffset) else { continue }
            guard lastLine > firstLine else { continue }
            for line in (firstLine + 1)...lastLine { collapsed.insert(line) }
        }
        collapsedContinuationLineIndices = collapsed
    }

    // MARK: - Invalidation

    /// Signals "this backing range's display may have changed" without actually changing any
    /// characters — `NSTextStorage.edited(_:range:changeInLength:)` with `changeInLength: 0` and no
    /// preceding `replaceCharacters` call is the standard, documented way to tell TextKit "re-ask
    /// my delegate for paragraphs in this range" without it being an editing operation the undo
    /// manager or `NSTextView`'s change-count/autosave machinery ever sees. Wrapped in
    /// `performEditingTransaction` so multiple calls in one recompute pass coalesce into a single
    /// layout pass instead of one per call.
    private func invalidateDisplay(for range: NSRange) {
        guard let textStorage = document.textContentStorage.textStorage, range.length >= 0 else { return }
        // Clamp defensively: a range computed against a slightly stale `source`/`lines` snapshot
        // must never be handed to `edited(_:range:changeInLength:)` extending past the storage's
        // *current* length, or it traps.
        let total = textStorage.length
        let location = max(0, min(range.location, total))
        let length = max(0, min(range.length, total - location))
        guard length > 0 else { return }
        let safeRange = NSRange(location: location, length: length)

        document.textContentStorage.performEditingTransaction {
            textStorage.edited(.editedAttributes, range: safeRange, changeInLength: 0)
        }
        onNeedsRedisplay?()
    }

    // MARK: - Async block rendering

    private func kickOffPendingRenders() {
        guard isEnabled else { return }
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let appearance = BlockImageRenderer.Appearance.resolve(from: NSApp.effectiveAppearance)

        for span in spans {
            let element: SyntaxElement
            let kind: BlockImageRenderer.Kind
            let content: String

            switch span {
            case .hiddenMarker, .substitutedMarker:
                continue
            case .renderedInline(let e):
                element = e
                switch e.kind {
                case .inlineMath: kind = .inlineMath
                case .displayMath: kind = .displayMath
                default: continue
                }
                content = sourceText(for: e.contentRange ?? e.range)
            case .renderedBlock(let e):
                element = e
                switch e.kind {
                case .table:
                    kind = .table
                    guard let html = MarkdownTableHTML.render(sourceText(for: e.range)) else { continue }
                    content = html
                case .diagramBlock:
                    kind = .mermaid
                    content = sourceText(for: e.contentRange ?? e.range)
                case .displayMath:
                    kind = .displayMath
                    content = sourceText(for: e.contentRange ?? e.range)
                default: continue
                }
            }

            let key = element.range
            guard renderedImages[key] == nil, !pendingRenders.contains(key) else { continue }
            pendingRenders.insert(key)

            BlockImageRenderer.shared.render(kind: kind, content: content, scale: screenScale, appearance: appearance, targetWidth: containerWidth) { [weak self] image in
                guard let self else { return }
                self.pendingRenders.remove(key)
                guard let image else { return }
                // The parse this render was requested against may already be stale (the user kept
                // typing while the async render was in flight) — only apply it if `elements` still
                // contains this exact range, otherwise silently discard rather than invalidating a
                // range that no longer means what it meant when the request was made.
                guard self.elements.contains(where: { $0.range == key }) else { return }
                self.renderedImages[key] = image
                self.invalidateDisplay(for: self.lineRange(containing: key).nsRange)
            }
        }
    }

    private func sourceText(for range: MDEdCore.TextRange) -> String {
        let ns = source as NSString
        let clamped = NSRange(location: max(0, min(range.lowerBound, ns.length)), length: 0)
        let upper = max(clamped.location, min(range.upperBound, ns.length))
        return ns.substring(with: NSRange(location: clamped.location, length: upper - clamped.location))
    }

    // MARK: - NSTextContentStorageDelegate

    func textParagraph(for textContentStorage: NSTextContentStorage, range: NSRange) -> NSTextParagraph? {
        guard isEnabled, let textStorage = textContentStorage.textStorage else { return nil }
        guard let lineIndex = lines.lineIndex(atUTF16Offset: range.location) else { return nil }

        // Collapsed continuation line: entirely inside a rendered block, not its carrier line.
        if collapsedContinuationLineIndices.contains(lineIndex) {
            let placeholder = NSAttributedString(string: Self.collapsedLinePlaceholder, attributes: [.font: Self.collapsedLineFont])
            return NSTextParagraph(attributedString: placeholder)
        }

        // Gather everything in `spans` that touches this paragraph's range as a flat list of
        // (source range, replacement) operations — a plain deletion (empty replacement) for a
        // hidden marker, an attachment-character replacement for a rendered element's one kept
        // unit. Handling every operation through one list, applied in a single descending-order
        // pass below, is what makes this correct for *any number* of rendered elements sharing one
        // paragraph (e.g. two `$inline$` spans on the same line) — an earlier version special-cased
        // a single attachment slot per paragraph and silently dropped every one after the first.
        //
        // Every clip below is bounded by `hideableRange`, not `range` itself — `range` (like
        // TextKit 2's own paragraph ranges generally) includes this paragraph's own trailing
        // paragraph-separator newline, and some marker ranges legitimately reach that far: a
        // list item's `genericMarkers` reports a *second* marker range past its last child
        // covering exactly that trailing `"\n"` (see `livePreviewSpans`'s `.listItem` case for
        // why hiding it is intentional — it's swift-markdown range noise, not real marker text),
        // and a heading/emphasis/etc. element's own range can overshoot the same way. Hiding a
        // *marker* is fine — collapsing it to zero display width is exactly what `DisplayMapper`
        // is for — but silently dropping the newline *character itself* from this custom
        // `NSTextParagraph`'s attributedString is not: TextKit 2 relies on that character
        // surviving verbatim to know where this paragraph ends and the next begins, and an
        // `NSTextParagraph` missing it produces a corrupted next-paragraph layout fragment
        // (observed as `LineNumberGutterView` silently drawing no number at all for that line,
        // or a later one, depending on how the corruption propagates). Clipping to one unit
        // short of `range` whenever that last unit is `"\n"` keeps the separator untouched while
        // changing nothing for the (common) case where a marker range doesn't reach that far.
        let hideableRange = trailingNewlineTrimmed(range, in: textStorage)
        var operations: [(range: MDEdCore.TextRange, replacement: NSAttributedString)] = []

        for span in spans {
            switch span {
            case .hiddenMarker(let r):
                if let clipped = clip(r, to: hideableRange) {
                    operations.append((clipped, NSAttributedString(string: "")))
                }
            case .renderedInline(let e), .renderedBlock(let e):
                guard e.range.length > 0 else { continue }
                let unit = MDEdCore.TextRange(lowerBound: e.range.lowerBound, upperBound: e.range.lowerBound + 1)
                let rest = MDEdCore.TextRange(lowerBound: e.range.lowerBound + 1, upperBound: e.range.upperBound)
                if let clippedRest = clip(rest, to: hideableRange) {
                    operations.append((clippedRest, NSAttributedString(string: "")))
                }
                if unit.lowerBound >= range.location, unit.upperBound <= range.location + range.length {
                    operations.append((unit, attachmentString(for: renderedImages[e.range])))
                }
            case .substitutedMarker(let r, let glyph):
                guard r.length > 0 else { continue }
                let keptLength = keptUnitLength(for: glyph, markerLength: r.length)
                let unit = MDEdCore.TextRange(lowerBound: r.lowerBound, upperBound: r.lowerBound + keptLength)
                let rest = MDEdCore.TextRange(lowerBound: r.lowerBound + keptLength, upperBound: r.upperBound)
                if let clippedRest = clip(rest, to: hideableRange) {
                    operations.append((clippedRest, NSAttributedString(string: "")))
                }
                if unit.lowerBound >= range.location, unit.upperBound <= range.location + range.length {
                    operations.append((unit, glyphString(glyph, replacing: unit, in: textStorage)))
                }
            }
        }

        guard !operations.isEmpty else { return nil }

        let result = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
        let base = range.location

        for operation in operations.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let localRange = NSRange(location: operation.range.lowerBound - base, length: operation.range.length)
            guard localRange.location >= 0, localRange.location + localRange.length <= result.length else { continue }
            result.replaceCharacters(in: localRange, with: operation.replacement)
        }

        return NSTextParagraph(attributedString: result)
    }

    /// The one-character `NSAttributedString` that stands in for a rendered element in the display
    /// text — the real image if `BlockImageRenderer` has already produced one, a small neutral
    /// placeholder glyph otherwise (swapped for the real image the moment the async render
    /// finishes, via `invalidateDisplay`, rather than flashing raw source for one frame).
    private func attachmentString(for image: NSImage?) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        if let image {
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -4, width: image.size.width / scale, height: image.size.height / scale)
        } else {
            attachment.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
            attachment.bounds = CGRect(x: 0, y: -4, width: 14, height: 14)
        }
        return NSAttributedString(attachment: attachment)
    }

    /// The one-character `NSAttributedString` that stands in for a list marker's substituted
    /// glyph (a bullet, a checkbox) — `glyph` itself, carrying whatever attributes the source
    /// text already had at `unit` (the font, and `MarkdownStyler`'s dimmed marker color) so the
    /// glyph sits at the same size/baseline/color a visible marker would, rather than resetting to
    /// `NSAttributedString`'s plain-text default (system font, label color) the way a bare
    /// `NSAttributedString(string:)` would.
    private func glyphString(_ glyph: String, replacing unit: MDEdCore.TextRange, in textStorage: NSTextStorage) -> NSAttributedString {
        guard unit.lowerBound < textStorage.length else { return NSAttributedString(string: glyph) }
        let attributes = textStorage.attributes(at: unit.lowerBound, effectiveRange: nil)
        return NSAttributedString(string: glyph, attributes: attributes)
    }

    /// How many of a `.substitutedMarker`'s own source UTF-16 units to keep (undeleted) as the
    /// display's stand-in for `glyph` — `glyph`'s own UTF-16 length, clamped to `markerLength` so
    /// a marker somehow shorter than its glyph (not reachable today: the shortest real marker is
    /// `"- "`, itself as long as the two-unit `"• "`/`"☐ "` glyphs) still can't ask for more units
    /// than the marker actually has. Shared between `rebuildMapper()` (what to hide) and
    /// `textParagraph(for:range:)` (what to replace) so the two can never disagree about where
    /// the kept prefix ends — a mismatch there would desync `DisplayMapper`'s offsets from what
    /// TextKit 2 actually lays out (a kept span whose replacement text is a different length than
    /// the span itself).
    private func keptUnitLength(for glyph: String, markerLength: Int) -> Int {
        min(glyph.utf16.count, markerLength)
    }

    /// `range` shortened by one UTF-16 unit if its last unit is `"\n"`, unchanged otherwise — see
    /// `textParagraph(for:range:)`'s `hideableRange` comment for why a paragraph's own trailing
    /// separator must never be offered up as something a marker-hiding operation can consume.
    private func trailingNewlineTrimmed(_ range: NSRange, in textStorage: NSTextStorage) -> NSRange {
        guard range.length > 0 else { return range }
        let lastUnitRange = NSRange(location: range.location + range.length - 1, length: 1)
        guard lastUnitRange.location + lastUnitRange.length <= textStorage.length else { return range }
        guard (textStorage.string as NSString).substring(with: lastUnitRange) == "\n" else { return range }
        return NSRange(location: range.location, length: range.length - 1)
    }

    /// `range` clipped to `bounds`, in source coordinates, or `nil` if they don't overlap.
    private func clip(_ range: MDEdCore.TextRange, to bounds: NSRange) -> MDEdCore.TextRange? {
        let lower = max(range.lowerBound, bounds.location)
        let upper = min(range.upperBound, bounds.location + bounds.length)
        guard lower < upper else { return nil }
        return MDEdCore.TextRange(lowerBound: lower, upperBound: upper)
    }
}

extension LivePreviewController: NSTextContentStorageDelegate {
    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        textParagraph(for: textContentStorage, range: range)
    }
}
