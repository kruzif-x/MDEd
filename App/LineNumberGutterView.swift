import Cocoa
import MDEdCore

/// A quiet line-number gutter for a TextKit 2 `NSTextView`, installed as its scroll view's
/// vertical ruler (`NSScrollView.verticalRulerView`) — the standard AppKit mechanism for a
/// persistent side column that tracks the document view's scroll position for free.
///
/// Line positions come from `NSTextLayoutManager.textLayoutFragment(for:)`, asked once per
/// *source* line (`MDEdCore.DocumentLines`) rather than via one continuous
/// `enumerateTextLayoutFragments` walk — see `drawHashMarksAndLabels`'s comment on that loop for
/// why a single walk isn't reliable here. `MarkdownTextView`'s block-background decorations use
/// the walk-based form of the same underlying API for its own, unrelated purpose (painting a
/// full-width fill behind a known *source range*, not enumerating the whole document every time),
/// so the two aren't actually solving the same problem despite both being TextKit 2 layout reads.
///
/// Numbering follows *source* lines, not visual (wrapped) lines, and agrees with everything else
/// in the app that counts lines because it's driven by the same `MDEdCore.DocumentLines` every
/// other line-aware feature (word count's line/column status, the comparison view's diff/hunk
/// machinery) already uses. Each `NSTextLayoutFragment` corresponds to one *paragraph* — and
/// paragraphs split on `"\n"`, the same separator `DocumentLines` splits on — so a wrapped
/// paragraph is still exactly one fragment and gets exactly one number, drawn once at the top of
/// that fragment. Its wrapped continuation lines live inside the same fragment as additional
/// `NSTextLineFragment`s this code never looks at, so they're never given a number of their own.
final class LineNumberGutterView: NSRulerView {

    private static let horizontalPadding: CGFloat = 6
    /// Reserves room for at least this many digits even in a short document, so the gutter doesn't
    /// visibly resize on almost every keystroke while a document is still small.
    private static let minimumDigits = 2

    private weak var hostTextView: NSTextView?

    /// Source-line indices (0-based, per `DocumentLines`) that should *not* get their own number
    /// drawn — the continuation lines of a live-preview-collapsed block (a table, Mermaid diagram,
    /// or multi-line `$$math$$`), whose first line already carries the block's single rendered
    /// image and whose own lines have collapsed to near-zero height. See `LivePreviewController`
    /// for how those lines are produced and `EditorViewController` for where this is kept current.
    ///
    /// **Decision:** the collapsed block gets *one* number, on its first source line, not a number
    /// per line distributed down the image. A rendered table image has no visual row-to-source-line
    /// correspondence a reader could line a distributed number up against in the first place (the
    /// separator row alone consumes a source line with no rendered counterpart at all), so
    /// distributing numbers down the image would either be meaningless or actively misleading.
    /// "This construct starts here" is the one honest, useful signal the gutter can give about a
    /// block it isn't otherwise visualizing line-by-line — consistent with how the *first* line of
    /// any multi-line construct is already the one users reach for (`⌘G`-style "go to line",
    /// hunk navigation elsewhere in this app) as the anchor for "the thing at line N".
    var collapsedContinuationLineIndices: Set<Int> = []

    /// Review-note markers, keyed by the source-line index (0-based, per `DocumentLines`) the
    /// note's anchor currently starts on — see `ReviewNotesController.gutterMarkers(in:)`.
    /// Drawn as small status-colored dots at the gutter's left edge, one per note starting on
    /// that line; the number labels keep the right-aligned side they've always had, so the two
    /// never collide.
    var noteMarkers: [Int: [NoteMarker]] = [:] {
        didSet { noteHitRects = []; needsDisplay = true }
    }

    /// Fires when the user clicks a note dot: the line it sits on, the note's ID, and the dot's
    /// frame in this view's coordinates (what the owner needs to anchor a popover to).
    var onNoteClick: ((Int, UUID, NSRect) -> Void)?

    /// The dots' clickable frames as the last draw pass laid them out — only *visible* dots
    /// are here, which is exactly the set a click could have meant. Rebuilt on every draw.
    private var noteHitRects: [(lineIndex: Int, noteID: UUID, rect: NSRect)] = []

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.hostTextView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used — this app has no storyboard/xib")
    }

    // MARK: - Accessibility
    //
    // A ruler view draws its numbers directly with `NSString.draw(in:withAttributes:)` — there is
    // no child accessibility element per glyph the way a real text view gets one for free, so
    // without the overrides below this entire column is silently invisible to VoiceOver: it's an
    // `NSRulerView`, which AppKit doesn't expose as an accessibility element by default at all.
    // Exposed as one element with a label and a value summarizing the current line count, rather
    // than one element per line — a screen reader user's own cursor-position announcement (driven
    // by `EditorViewController`'s status line, which already reports "Ln N, Col M" on every
    // caret move) is the actually useful "where am I" signal; duplicating that per gutter number
    // would be noise, not information.

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Line numbers" }

    override func accessibilityValue() -> Any? {
        let count = max(1, DocumentLines(hostTextView?.string ?? "").count)
        return count == 1 ? "1 line" : "\(count) lines"
    }

    /// Recomputes the gutter's width for the current line count and font, and asks the scroll view
    /// to re-tile if it changed. Called whenever the document's line count might have crossed a
    /// decimal-digit boundary (9→10 lines, 99→100, …) — the only time the gutter actually needs to
    /// get wider or narrower — so a normal edit that doesn't add a digit costs nothing beyond the
    /// cheap `DocumentLines` count.
    func updateThickness() {
        guard let textView = hostTextView else { return }
        let font = gutterFont()
        let lineCount = max(1, DocumentLines(textView.string).count)
        let digits = max(Self.minimumDigits, String(lineCount).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(CGFloat(digits) * digitWidth) + Self.horizontalPadding * 2
        if abs(thickness - ruleThickness) > 0.5 {
            ruleThickness = thickness
            scrollView?.tile()
        }
    }

    /// The document's *body* font (from Settings), sized down five points and switched to
    /// fixed-width digits — legible at a glance, unmistakably a supporting element rather than
    /// more text to read.
    ///
    /// Deliberately `MarkdownStyler.baseFont`, **not** `textView.font`: once the styler has run,
    /// `NSTextView.font` reflects the attributes at the caret, not the body font this view was
    /// configured with — opening any document that *starts with a heading* made the gutter read
    /// the heading's 22pt as its base, rendering numbers up to three sizes larger than intended
    /// (and, with a number box taller than the body's line boxes, clipped at the viewport
    /// edges). `baseFont` is the caret-independent truth, and the gutter already redraws on
    /// every Settings change (the restyle pass calls `invalidateGutterFully()`).
    private func gutterFont() -> NSFont {
        let base = MarkdownStyler.baseFont(EditorSettings.current())
        let size = max(7, base.pointSize - 5)
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = hostTextView,
              let textLayoutManager = textView.textLayoutManager,
              let contentManager = textLayoutManager.textContentManager
        else { return }

        // `rect` is documented as "the rectangle needing drawing", but in practice AppKit hands
        // this override a rect tied to the *client view*'s dirty region — observed, on a 47pt-wide
        // gutter, to come in over 1000pt wide, far past `self.bounds`. Filling or drawing with it
        // directly paints straight through the gutter's own narrow column and over the real editor
        // text sitting to its right. Everything below is explicitly clipped to `bounds` — this
        // view's actual, honest width — instead of trusting `rect`.
        let graphicsContext = NSGraphicsContext.current
        graphicsContext?.saveGraphicsState()
        defer { graphicsContext?.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()

        noteHitRects = []

        (textView.backgroundColor).setFill()
        bounds.fill()

        let lines = DocumentLines(textView.string)
        let docLocation = contentManager.documentRange.location
        let origin = textView.textContainerOrigin
        let font = gutterFont()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ]
        let labelWidth = max(0, ruleThickness - Self.horizontalPadding)

        // A genuinely empty document (a brand-new "Untitled" window, or every line deleted) has
        // zero length, and `NSTextLayoutManager` enumerates *zero* layout fragments for zero-length
        // content — there's no paragraph object for it to hand back. The loop below would then
        // draw nothing at all, leaving the gutter blank even though `DocumentLines("")` (like every
        // other line-aware feature in this app) still reports one real line. Handled by hand here,
        // using the same line-height fallback `ComparePaneViewController` uses for the same reason.
        guard !textView.string.isEmpty else {
            // `baseFont` for the same reason `gutterFont()` avoids `textView.font` — see its
            // doc comment.
            let textFont = MarkdownStyler.baseFont(EditorSettings.current())
            let height = textFont.ascender - textFont.descender + textFont.leading
            let rulerOrigin = self.convert(NSPoint(x: 0, y: origin.y), from: textView)
            let labelRect = NSRect(x: 0, y: rulerOrigin.y, width: labelWidth, height: height)
            if labelRect.intersects(bounds) {
                // Same exact-fit, vertically-centered drawing as the main loop below.
                let one = "1" as NSString
                let oneSize = one.size(withAttributes: attributes)
                one.draw(
                    in: NSRect(x: 0, y: labelRect.midY - oneSize.height / 2, width: labelWidth, height: oneSize.height),
                    withAttributes: attributes
                )
            }
            return
        }

        // One direct fragment lookup per *source* line (`DocumentLines`), rather than a single
        // `enumerateTextLayoutFragments` walk from the document start. The two should be
        // equivalent — each source line maps to exactly one paragraph/fragment — but under live
        // preview (where most paragraphs arrive from `LivePreviewController`'s
        // `NSTextContentStorageDelegate` as substituted, shorter-than-source attributed strings
        // rather than the content storage's own default paragraphs) a single continuous
        // enumeration starting from `docLocation` was observed to silently skip drawing a number
        // for an arbitrary line here and there — reproducibly, for a given scroll history, but
        // varying with it — while every fragment it *did* visit still resolved to the correct
        // line. That points at the batch walk itself picking up a stale/inconsistent
        // `layoutFragmentFrame` for a fragment TextKit 2 had to re-materialize after the
        // document scrolled far away and back (evicting it from the viewport layout controller's
        // cache), not at anything wrong with this view's own offset/line-index math. Asking for
        // each line's fragment independently — `textLayoutFragment(for:)`, which lays out on
        // demand exactly like `enumerateTextLayoutFragments(options: [.ensuresLayout])` claims to
        // — sidesteps whatever ordering/caching state the continuous walk was accumulating,
        // without needing to know its exact mechanism. Cost is comparable, not worse: the walk
        // this replaces already visited every fragment in the document on every redraw (it never
        // stopped early, even past `bounds`), so this is the same total amount of layout work,
        // just requested per line instead of as one continuous traversal.
        for lineIndex in 0..<lines.count {
            guard !self.collapsedContinuationLineIndices.contains(lineIndex) else { continue }

            let lineStartOffset = lines.lineRanges[lineIndex].lowerBound
            guard let location = contentManager.location(docLocation, offsetBy: lineStartOffset) else { continue }
            guard let fragment = textLayoutManager.textLayoutFragment(for: location) else { continue }

            let frame = fragment.layoutFragmentFrame

            // A fragment's frame spans the paragraph's whole box, which for a heading includes the
            // spacing-before that `MarkdownStyler` adds proportional to heading level. Anchoring
            // the number to `frame.minY` floats it up into that empty gap instead of setting it
            // beside the glyphs — visibly wrong on every heading while looking perfectly fine on
            // body text, which is how it escaped notice. Anchor to the first *line* fragment's own
            // typographic box, which begins where the glyphs actually do.
            let firstLine = fragment.textLineFragments.first
            let glyphOffset = firstLine?.typographicBounds.minY ?? 0
            let lineHeight = firstLine?.typographicBounds.height ?? frame.height

            let textViewPoint = NSPoint(x: 0, y: frame.minY + glyphOffset + origin.y)
            let rulerOrigin = self.convert(textViewPoint, from: textView)
            let labelRect = NSRect(x: 0, y: rulerOrigin.y, width: labelWidth, height: lineHeight)
            guard labelRect.intersects(bounds) else { continue }

            // Draw into a rect that is *exactly* the number's own height, vertically centered
            // on the body line's box. Drawing into the full line-height rect instead lays the
            // number out from the rect's top, leaving its fit-to-height (and with it the
            // descender's survival) incidental rather than guaranteed — the cause of numbers
            // clipping at the bottom whenever the gutter font and the line's height drift
            // apart. An exact-fit rect can't clip by construction, and centering reads better
            // than top-hugging on tall lines.
            let numberString = "\(lineIndex + 1)" as NSString
            let numberSize = numberString.size(withAttributes: attributes)
            let numberRect = NSRect(
                x: 0,
                y: labelRect.midY - numberSize.height / 2,
                width: labelWidth,
                height: numberSize.height
            )
            // A number whose box straddles the ruler's top or bottom edge — the line the
            // viewport has scrolled part-way past — renders as a half-cut digit. Skip it
            // instead: the number reappears the moment its line is fully back in view, and no
            // digit is ever visibly chopped. (0.5pt tolerance absorbs sub-pixel rounding at
            // an edge a number exactly abuts.)
            guard numberRect.minY >= bounds.minY - 0.5, numberRect.maxY <= bounds.maxY + 0.5 else { continue }
            numberString.draw(in: numberRect, withAttributes: attributes)

            drawNoteDots(for: lineIndex, in: labelRect)
        }
    }

    /// Paints this line's note dots at the gutter's left edge and records their hit rects.
    /// Sits inside the per-line loop (after the `labelRect.intersects(bounds)` guard), so
    /// `noteHitRects` only ever contains dots that are actually on screen — the same set a
    /// click could have meant.
    private func drawNoteDots(for lineIndex: Int, in labelRect: NSRect) {
        guard let markers = noteMarkers[lineIndex], !markers.isEmpty else { return }
        for (offset, marker) in markers.enumerated() {
            let diameter: CGFloat = 5
            let dotRect = NSRect(
                x: Self.horizontalPadding / 2 - diameter / 2 + CGFloat(offset) * 7,
                y: labelRect.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            marker.kind.nsColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            noteHitRects.append((lineIndex, marker.noteID, dotRect.insetBy(dx: -3, dy: -3)))
        }
    }

    /// A click on a note dot opens that note's detail popover (via `onNoteClick`); a click
    /// anywhere else falls through to `NSRulerView`'s own handling, which for a ruler with no
    /// client-view-driven interactions means "do nothing" — the gutter has never been
    /// interactive before, so nothing existing can regress.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = noteHitRects.first(where: { $0.rect.contains(point) }) {
            onNoteClick?(hit.lineIndex, hit.noteID, hit.rect)
        } else {
            super.mouseDown(with: event)
        }
    }
}
