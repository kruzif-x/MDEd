/// The minimal line-index-range edit needed to apply a hunk: which span of lines on the *losing*
/// (target) side to replace, and what lines should replace it.
///
/// This is the line-index-only cousin of `applying(_:to:direction:)`, which returns a whole new
/// line array for the losing side. `HunkLineEdit` exists for callers — like a text view — that
/// want to make the smallest possible edit (so an unrelated cursor position or scroll offset
/// elsewhere in a large document isn't disturbed) rather than replace the entire document text.
public struct HunkLineEdit: Sendable, Equatable {
    /// The range of line indices, on the losing side, to replace. Empty (`lowerBound == upperBound`)
    /// when the hunk has no existing lines on that side to overwrite (a pure insertion/removal
    /// being applied onto the side that never had it) — in that case this is the correct insertion
    /// point, not "nowhere to edit".
    public let targetLineRange: Range<Int>
    /// The lines that should replace `targetLineRange`.
    public let replacementLines: [String]

    public init(targetLineRange: Range<Int>, replacementLines: [String]) {
        self.targetLineRange = targetLineRange
        self.replacementLines = replacementLines
    }
}

/// Computes the minimal line-range edit that applies `hunk` in `direction`.
///
/// For a hunk that has an existing range on the losing side (the ordinary case — a `.changed` run,
/// or a `.removed` run being taken-right onto the left, etc.) this is just that range. For a hunk
/// that exists on only one side (a pure insertion or pure removal being applied onto the side that
/// has nothing there yet), there is no existing range to report — instead this finds the correct
/// *insertion point* by looking at what comes immediately after the hunk in `result`'s entries:
/// the next entry that has an index on the losing side (guaranteed to exist unless the hunk is the
/// last thing in the document, in which case the insertion point is simply the end).
public func lineEdit(for hunk: Hunk, in result: LineDiffResult, direction: HunkApplyDirection) -> HunkLineEdit {
    switch direction {
    case .takeLeft:
        let replacement = hunk.leftRange.map { Array(result.leftLines[$0]) } ?? []
        if let r = hunk.rightRange {
            return HunkLineEdit(targetLineRange: r, replacementLines: replacement)
        }
        let insertionPoint = insertionIndex(after: hunk, in: result, side: \.rightIndex, fallback: result.rightLines.count)
        return HunkLineEdit(targetLineRange: insertionPoint..<insertionPoint, replacementLines: replacement)

    case .takeRight:
        let replacement = hunk.rightRange.map { Array(result.rightLines[$0]) } ?? []
        if let l = hunk.leftRange {
            return HunkLineEdit(targetLineRange: l, replacementLines: replacement)
        }
        let insertionPoint = insertionIndex(after: hunk, in: result, side: \.leftIndex, fallback: result.leftLines.count)
        return HunkLineEdit(targetLineRange: insertionPoint..<insertionPoint, replacementLines: replacement)
    }
}

private func insertionIndex(after hunk: Hunk, in result: LineDiffResult, side: KeyPath<LineDiffEntry, Int?>, fallback: Int) -> Int {
    guard let firstEntry = hunk.entries.first,
          let startIndex = result.entries.firstIndex(of: firstEntry)
    else { return fallback }
    let afterHunk = result.entries[(startIndex + hunk.entries.count)...]
    return afterHunk.first { $0[keyPath: side] != nil }?[keyPath: side] ?? fallback
}

/// A concrete text edit — a UTF-16 range to replace and the exact string to replace it with —
/// realizing a `HunkLineEdit` against a specific document's actual text, ready to hand to
/// `NSTextView.insertText(_:replacementRange:)` (or equivalent) so the edit goes through the
/// normal, undoable editing pipeline instead of a raw text-storage rebuild.
public struct TextEdit: Sendable, Equatable {
    public let range: TextRange
    public let replacementText: String

    public init(range: TextRange, replacementText: String) {
        self.range = range
        self.replacementText = replacementText
    }
}

/// Turns a `HunkLineEdit`'s line indices into an actual `TextEdit` against `lines`, gluing on
/// whichever newline the insertion needs (a mid-document insertion point needs a trailing
/// separator to detach it from the line that follows; an end-of-document insertion point needs a
/// leading one) so the result is well-formed text regardless of which case applies.
///
/// - Precondition: `lineEdit` was computed from the same document `lines` represents (or an
///   equivalent one) — passing a line range out of bounds for `lines` produces a `TextEdit`
///   clamped to the nearest valid boundary rather than trapping.
public func textEdit(for lineEdit: HunkLineEdit, in lines: DocumentLines) -> TextEdit {
    let count = lines.count
    let lower = max(0, min(lineEdit.targetLineRange.lowerBound, count))
    let upper = max(lower, min(lineEdit.targetLineRange.upperBound, count))
    let joinedReplacement = lineEdit.replacementLines.joined(separator: "\n")

    if lower < upper {
        // Replacing (or, if `replacementLines` is empty, deleting) an existing span of lines.
        // The range always swallows exactly one of the newlines bracketing the span — the
        // trailing one if a following line exists to reattach to, otherwise the leading one — so
        // deleting every line in the span never leaves a stray blank line behind, and the
        // replacement text glues the matching newline back on only when there is new content to
        // separate from its neighbor.
        if upper < count {
            let start = lines.lineRanges[lower].lowerBound
            let end = lines.lineRanges[upper].lowerBound // start of the line right after the span
            let text = joinedReplacement.isEmpty ? "" : joinedReplacement + "\n"
            return TextEdit(range: TextRange(lowerBound: start, upperBound: end), replacementText: text)
        }
        if lower > 0 {
            let start = lines.lineRanges[lower - 1].upperBound // end of the line right before the span
            let end = lines.lineRanges[upper - 1].upperBound
            let text = joinedReplacement.isEmpty ? "" : "\n" + joinedReplacement
            return TextEdit(range: TextRange(lowerBound: start, upperBound: end), replacementText: text)
        }
        // The span is the entire document (lower == 0, upper == count): no bracketing newline on
        // either side to preserve or consume.
        let end = count > 0 ? lines.lineRanges[count - 1].upperBound : 0
        return TextEdit(range: TextRange(lowerBound: 0, upperBound: end), replacementText: joinedReplacement)
    }

    guard lower < count else {
        // Inserting after the last line (including possibly the document's own trailing empty
        // line): glue a leading newline onto the new content to start it on its own line.
        let end = count > 0 ? lines.lineRanges[count - 1].upperBound : 0
        let text = (count > 0 ? "\n" : "") + joinedReplacement
        return TextEdit(range: TextRange(lowerBound: end, upperBound: end), replacementText: text)
    }
    // Inserting before an existing line: glue a trailing newline onto the new content to push
    // that line down rather than merging into it.
    let start = lines.lineRanges[lower].lowerBound
    let text = joinedReplacement + "\n"
    return TextEdit(range: TextRange(lowerBound: start, upperBound: start), replacementText: text)
}
