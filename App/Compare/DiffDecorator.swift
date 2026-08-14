import Cocoa
import MDEdCore

/// Which pane a piece of diff decoration is being computed for.
enum DiffSide {
    case left
    case right
}

/// Turns `MDEdCore`'s line- and word-level diff results into the two kinds of decoration
/// `MarkdownTextView` knows how to paint: full-line tints (`DiffLineHighlight`, block-style — see
/// that type) and word-level emphasis (plain `NSTextStorage` attributes, applied the same way
/// `MarkdownStyler` applies inline styling).
enum DiffDecorator {

    /// The full-line tints for `side`: a `.removed`/`.changed` line tints red on the left, an
    /// `.inserted`/`.changed` line tints green on the right — see `DiffLineHighlight.Kind`'s
    /// documentation for why both "pure" and "changed" lines share one color per side.
    static func lineHighlights(for side: DiffSide, entries: [LineDiffEntry], lines: DocumentLines) -> [DiffLineHighlight] {
        var highlights: [DiffLineHighlight] = []
        for entry in entries {
            switch (side, entry.kind) {
            case (.left, .removed), (.left, .changed):
                if let l = entry.leftIndex, lines.lineRanges.indices.contains(l) {
                    highlights.append(DiffLineHighlight(range: lines.lineRanges[l].nsRange, kind: .removed))
                }
            case (.right, .inserted), (.right, .changed):
                if let r = entry.rightIndex, lines.lineRanges.indices.contains(r) {
                    highlights.append(DiffLineHighlight(range: lines.lineRanges[r].nsRange, kind: .added))
                }
            default:
                break
            }
        }
        return highlights
    }

    /// Applies word-level emphasis to every `.changed` entry's line on `side`, as real text
    /// attributes layered on top of whatever `MarkdownStyler.restyle` already set — the caller is
    /// expected to have just restyled `textStorage`, the same "attributes only, inside
    /// beginEditing/endEditing" discipline `MarkdownStyler` itself follows.
    static func applyWordHighlights(
        to textStorage: NSTextStorage,
        side: DiffSide,
        entries: [LineDiffEntry],
        leftLines: DocumentLines,
        rightLines: DocumentLines
    ) {
        let changedEntries = entries.filter { $0.kind == .changed }
        guard !changedEntries.isEmpty else { return }

        textStorage.beginEditing()
        for entry in changedEntries {
            guard let l = entry.leftIndex, let r = entry.rightIndex,
                  leftLines.lines.indices.contains(l), rightLines.lines.indices.contains(r)
            else { continue }
            let words = diffWords(leftLines.lines[l], rightLines.lines[r])
            switch side {
            case .left:
                let base = leftLines.lineRanges[l].lowerBound
                for span in words.oldSpans where span.kind == .removed {
                    apply(.removed, span: span, base: base, to: textStorage)
                }
            case .right:
                let base = rightLines.lineRanges[r].lowerBound
                for span in words.newSpans where span.kind == .inserted {
                    apply(.added, span: span, base: base, to: textStorage)
                }
            }
        }
        textStorage.endEditing()
    }

    private static func apply(_ kind: DiffLineHighlight.Kind, span: WordDiffSpan, base: Int, to textStorage: NSTextStorage) {
        guard span.range.length > 0 else { return }
        let range = NSRange(location: base + span.range.lowerBound, length: span.range.length)
        guard range.location >= 0, range.location + range.length <= textStorage.length else { return }
        let color: NSColor = kind == .removed
            ? NSColor.systemRed.withAlphaComponent(0.32)
            : NSColor.systemGreen.withAlphaComponent(0.32)
        textStorage.addAttribute(.backgroundColor, value: color, range: range)
    }
}
