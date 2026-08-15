import Cocoa
import MDEdCore

/// A quiet line-number gutter for a TextKit 2 `NSTextView`, installed as its scroll view's
/// vertical ruler (`NSScrollView.verticalRulerView`) — the standard AppKit mechanism for a
/// persistent side column that tracks the document view's scroll position for free.
///
/// Line positions come from the exact technique `MarkdownTextView` already uses for its
/// block-background decorations (see that class's doc comment): enumerating
/// `NSTextLayoutManager.enumerateTextLayoutFragments` and reading each fragment's
/// `layoutFragmentFrame`, rather than a second, independent measurement approach.
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

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.hostTextView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used — this app has no storyboard/xib")
    }

    /// Recomputes the gutter's width for the current line count and font, and asks the scroll view
    /// to re-tile if it changed. Called whenever the document's line count might have crossed a
    /// decimal-digit boundary (9→10 lines, 99→100, …) — the only time the gutter actually needs to
    /// get wider or narrower — so a normal edit that doesn't add a digit costs nothing beyond the
    /// cheap `DocumentLines` count.
    func updateThickness() {
        guard let textView = hostTextView else { return }
        let font = gutterFont(basedOn: textView)
        let lineCount = max(1, DocumentLines(textView.string).count)
        let digits = max(Self.minimumDigits, String(lineCount).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(CGFloat(digits) * digitWidth) + Self.horizontalPadding * 2
        if abs(thickness - ruleThickness) > 0.5 {
            ruleThickness = thickness
            scrollView?.tile()
        }
    }

    /// The editor's own font, sized down and switched to fixed-width digits — legible at a glance,
    /// unmistakably a supporting element rather than more text to read.
    private func gutterFont(basedOn textView: NSTextView) -> NSFont {
        let base = textView.font ?? NSFont.systemFont(ofSize: 13)
        let size = max(9, base.pointSize - 3)
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

        (textView.backgroundColor).setFill()
        bounds.fill()

        let lines = DocumentLines(textView.string)
        let docLocation = contentManager.documentRange.location
        let origin = textView.textContainerOrigin
        let font = gutterFont(basedOn: textView)

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
            let textFont = textView.font ?? MarkdownStyler.baseFont(EditorSettings.current())
            let height = textFont.ascender - textFont.descender + textFont.leading
            let rulerOrigin = self.convert(NSPoint(x: 0, y: origin.y), from: textView)
            let labelRect = NSRect(x: 0, y: rulerOrigin.y, width: labelWidth, height: height)
            if labelRect.intersects(bounds) {
                ("1" as NSString).draw(in: labelRect, withAttributes: attributes)
            }
            return
        }

        textLayoutManager.enumerateTextLayoutFragments(from: docLocation, options: [.ensuresLayout]) { fragment in
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
            guard labelRect.intersects(bounds) else { return true }

            let fragmentRange = fragment.rangeInElement
            let startOffset = contentManager.offset(from: docLocation, to: fragmentRange.location)
            guard startOffset >= 0, let lineIndex = lines.lineIndex(atUTF16Offset: startOffset) else { return true }
            guard !self.collapsedContinuationLineIndices.contains(lineIndex) else { return true }

            let numberString = "\(lineIndex + 1)"
            (numberString as NSString).draw(in: labelRect, withAttributes: attributes)
            return true
        }
    }
}
