import Cocoa

/// One block-level element (code block, table, or block quote) that needs a background painted
/// behind its line fragments rather than hugging its glyphs — see `MarkdownStyler`'s doc comment
/// for why glyph-hugging backgrounds are wrong for these.
struct BlockDecoration {
    enum Kind {
        case code
        case table
        case quote
    }

    let range: NSRange
    let kind: Kind
}

/// One line's diff classification, painted as a full-width tint behind its glyphs — the
/// comparison view's counterpart to `BlockDecoration`, using the exact same painting mechanism
/// (see this class's doc comment) rather than a new one. `range` is expected to span one source
/// line (as reported by `DocumentLines`); a multi-line `range` paints a single continuous tint
/// across all of them, same as a multi-line `BlockDecoration` already does.
struct DiffLineHighlight {
    enum Kind {
        /// This pane holds the "before" content of a difference — a removed line, or the left
        /// side of a changed line.
        case removed
        /// This pane holds the "after" content of a difference — an inserted line, or the right
        /// side of a changed line.
        case added
    }

    let range: NSRange
    let kind: Kind
}

/// An `NSTextView` that paints `diffHighlights` and `blockDecorations` behind its line fragments
/// before the glyphs draw on top, so a block's or a diff line's fill is one continuous shape
/// regardless of blank lines, trailing whitespace, or short lines inside it.
///
/// This is the TextKit 2 counterpart of the old TextKit 1 trick of asking the layout manager for
/// per-line `lineFragmentRect(forGlyphAt:effectiveRange:)` rects and unioning them. TextKit 2 has
/// no glyph indices; the equivalent is enumerating `NSTextLayoutFragment`s over an `NSTextRange`
/// and using each fragment's `layoutFragmentFrame`, which already covers the fragment's full line
/// height even when the line is empty — that's what makes a blank line inside a fenced code block
/// still contribute to the fill instead of poking a hole in it.
///
/// One non-obvious requirement this needs from its owner: `drawsBackground = false`. `NSTextView`'s
/// own `draw(_:)` implementation paints an opaque wash of `backgroundColor` across the *entire*
/// dirty rect before drawing glyphs. Since that happens inside `super.draw(_:)` — necessarily
/// *after* this override's own painting, so glyphs land on top — it would silently erase everything
/// painted here on every redraw. With `drawsBackground` off, this override paints the base fill
/// itself first, then the decorations, then defers to `super` for glyphs/selection/insertion point
/// only, none of which touches pixels outside actual text content.
final class MarkdownTextView: NSTextView {

    var blockDecorations: [BlockDecoration] = [] {
        didSet { needsDisplay = true }
    }

    /// Diff line tints for the comparison view. Empty (the default) for every ordinary editor tab
    /// — only a comparison pane ever sets this, and only when parallel-reading mode is off.
    var diffHighlights: [DiffLineHighlight] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        (backgroundColor).setFill()
        dirtyRect.fill()
        // Diff tints paint first (full-bleed, the "base wash" for the line), so structural block
        // decorations — a code block that also happens to be a changed line, say — layer visibly
        // on top rather than being hidden underneath.
        drawDiffHighlights(in: dirtyRect)
        drawBlockBackgrounds(in: dirtyRect)
        super.draw(dirtyRect)
    }

    // MARK: - Background painting

    private func drawDiffHighlights(in dirtyRect: NSRect) {
        guard !diffHighlights.isEmpty else { return }
        forEachVerticalSpan(of: diffHighlights.map(\.range), in: dirtyRect) { highlight, span in
            drawDiffTint(highlight.kind, in: span)
        } lookup: { index in diffHighlights[index] }
    }

    private func drawBlockBackgrounds(in dirtyRect: NSRect) {
        guard !blockDecorations.isEmpty else { return }
        forEachVerticalSpan(of: blockDecorations.map(\.range), in: dirtyRect) { decoration, span in
            draw(decoration.kind, in: span)
        } lookup: { index in blockDecorations[index] }
    }

    /// Shared traversal for both decoration kinds: resolves each `ranges[i]`'s on-screen vertical
    /// span via TextKit 2 layout fragments, skips it if that span doesn't intersect `dirtyRect`,
    /// and otherwise invokes `paint` with the item `lookup(i)` produces alongside the resolved
    /// full-width rect — the geometry work is identical between block decorations and diff
    /// highlights; only what gets drawn into the rect differs.
    private func forEachVerticalSpan<T>(
        of ranges: [NSRange],
        in dirtyRect: NSRect,
        paint: (T, NSRect) -> Void,
        lookup: (Int) -> T
    ) {
        guard let textLayoutManager,
              let contentManager = textLayoutManager.textContentManager,
              let textContainer
        else { return }

        let origin = textContainerOrigin
        let contentWidth = textContainer.size.width

        for (index, range) in ranges.enumerated() {
            guard let span = verticalSpan(for: range, layoutManager: textLayoutManager, contentManager: contentManager) else { continue }
            let rect = NSRect(x: origin.x, y: origin.y + span.minY, width: contentWidth, height: span.maxY - span.minY)
            // Every fill this method produces spans (at least) the container's full width, so only
            // the vertical overlap with `dirtyRect` actually decides visibility.
            guard rect.maxY >= dirtyRect.minY, rect.minY <= dirtyRect.maxY else { continue }
            paint(lookup(index), rect)
        }
    }

    /// The union, in text-container coordinates, of every layout fragment's frame that overlaps
    /// `nsRange` — i.e. the vertical span (`minY`...`maxY`) the block occupies on screen. Fragment
    /// x/width is ignored on purpose: the fill is meant to span the *full* content width, not just
    /// wherever glyphs happen to reach.
    private func verticalSpan(for nsRange: NSRange, layoutManager: NSTextLayoutManager, contentManager: NSTextContentManager) -> (minY: CGFloat, maxY: CGFloat)? {
        guard nsRange.length > 0 else { return nil }
        let docLocation = contentManager.documentRange.location
        guard let start = contentManager.location(docLocation, offsetBy: nsRange.location) else { return nil }

        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        var found = false
        let upperBound = nsRange.location + nsRange.length

        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let fragmentRange = fragment.rangeInElement
            let fragStart = contentManager.offset(from: docLocation, to: fragmentRange.location)
            guard fragStart < upperBound else { return false }

            let fragEnd = contentManager.offset(from: docLocation, to: fragmentRange.endLocation)
            if fragEnd > nsRange.location {
                let frame = fragment.layoutFragmentFrame
                minY = min(minY, frame.minY)
                maxY = max(maxY, frame.maxY)
                found = true
            }
            return true
        }

        return found ? (minY, maxY) : nil
    }

    // MARK: - Shapes

    private func draw(_ kind: BlockDecoration.Kind, in rect: NSRect) {
        let bleed: CGFloat = kind == .quote ? 0 : 16
        let bled = rect.insetBy(dx: -bleed, dy: 0)
        let padded = NSRect(x: bled.minX, y: bled.minY - 2, width: bled.width, height: bled.height + 4)

        switch kind {
        case .code:
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: padded, xRadius: 6, yRadius: 6).fill()

        case .table:
            NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: padded, xRadius: 6, yRadius: 6).fill()

        case .quote:
            NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: padded, xRadius: 4, yRadius: 4).fill()

            let barRect = NSRect(x: padded.minX + 3, y: padded.minY + 1, width: 3, height: max(0, padded.height - 2))
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawDiffTint(_ kind: DiffLineHighlight.Kind, in rect: NSRect) {
        let color: NSColor
        switch kind {
        case .removed: color = NSColor.systemRed.withAlphaComponent(0.12)
        case .added: color = NSColor.systemGreen.withAlphaComponent(0.12)
        }
        color.setFill()
        // Full-bleed, no rounding, no inset — a solid gutter-to-gutter tint reads as "this whole
        // line is part of the diff" the way a code/table/quote block's rounded inset fill (meant
        // to read as one discrete embedded object) deliberately doesn't. Stretched to the view's
        // own bounds (not just the text container) so the tint reaches both edges regardless of
        // the current measure/margin.
        NSRect(x: bounds.minX, y: rect.minY, width: bounds.width, height: rect.height).fill()
    }
}
