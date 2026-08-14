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

/// An `NSTextView` that paints `blockDecorations` behind its line fragments before the glyphs draw
/// on top, so a block's fill is one continuous shape regardless of blank lines, trailing
/// whitespace, or short lines inside it.
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

    override func draw(_ dirtyRect: NSRect) {
        (backgroundColor).setFill()
        dirtyRect.fill()
        drawBlockBackgrounds(in: dirtyRect)
        super.draw(dirtyRect)
    }

    // MARK: - Background painting

    private func drawBlockBackgrounds(in dirtyRect: NSRect) {
        guard !blockDecorations.isEmpty,
              let textLayoutManager,
              let contentManager = textLayoutManager.textContentManager,
              let textContainer
        else { return }

        let origin = textContainerOrigin
        let contentWidth = textContainer.size.width

        for decoration in blockDecorations {
            guard let span = verticalSpan(for: decoration.range, layoutManager: textLayoutManager, contentManager: contentManager) else { continue }

            let bleed: CGFloat = decoration.kind == .quote ? 0 : 16
            let rect = NSRect(
                x: origin.x - bleed,
                y: origin.y + span.minY - 2,
                width: contentWidth + bleed * 2,
                height: (span.maxY - span.minY) + 4
            )
            guard dirtyRect.intersects(rect) else { continue }
            draw(decoration.kind, in: rect)
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
        switch kind {
        case .code:
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        case .table:
            NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        case .quote:
            NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

            let barRect = NSRect(x: rect.minX + 3, y: rect.minY + 1, width: 3, height: max(0, rect.height - 2))
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
