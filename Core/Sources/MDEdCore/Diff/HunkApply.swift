/// Which side "wins" when a hunk is applied — i.e. which side's content the *other* side adopts.
public enum HunkApplyDirection: Sendable, Equatable {
    /// The left side's content for this hunk overwrites the right side's ("take left").
    case takeLeft
    /// The right side's content for this hunk overwrites the left side's ("take right").
    case takeRight
}

/// The result of applying one hunk: both documents' full line arrays after the change, ready to
/// be joined back into text (e.g. `lines.joined(separator: "\n")`) by the caller.
///
/// Applying a hunk only ever changes *one* side — `takeLeft` changes `rightLines`, `takeRight`
/// changes `leftLines` — the other side's array is returned unmodified (`==` the input) so a
/// caller can diff old-vs-new to find exactly what changed, or just always use both fields
/// unconditionally without a direction check of its own.
public struct HunkApplyResult: Sendable, Equatable {
    public let leftLines: [String]
    public let rightLines: [String]

    public init(leftLines: [String], rightLines: [String]) {
        self.leftLines = leftLines
        self.rightLines = rightLines
    }
}

/// Applies `hunk` — one contiguous run of change from `hunks(in:)`, called out on `result` — to
/// `result`, producing the full line arrays of both documents after the losing side adopts the
/// winning side's content for exactly that hunk's span.
///
/// This resolves the "where do these lines go on the side that doesn't have them yet" question
/// (relevant for a hunk that's a pure insertion or pure removal on the source side, where there is
/// no existing sub-range on the target side to overwrite) by walking `result.entries` in document
/// order rather than trying to compute an insertion index from `hunk.leftRange`/`hunk.rightRange`
/// alone: every entry belonging to `hunk` contributes the winning side's line (if it has one);
/// every entry *not* belonging to `hunk` contributes whatever the target side already had. This
/// also makes the operation correct even when `hunk` sits at either end of the document, and is
/// the same technique `LineAlignmentMap` uses to reason about the boundary anchors.
///
/// - Precondition: `hunk`'s entries must actually be a subset of `result.entries` (i.e. `hunk`
///   came from `hunks(in: result)`, not from some unrelated diff). Passing a hunk from a different
///   result produces an output where nothing in `hunk` matches anything in `result`, so the target
///   side comes back unchanged — a safe, if useless, degenerate result rather than a crash.
public func applying(_ hunk: Hunk, to result: LineDiffResult, direction: HunkApplyDirection) -> HunkApplyResult {
    let hunkEntries = Set(hunk.entries)

    switch direction {
    case .takeLeft:
        // Right adopts left's content for this hunk; left is untouched.
        var newRight: [String] = []
        newRight.reserveCapacity(result.rightLines.count)
        for entry in result.entries {
            if hunkEntries.contains(entry) {
                if let l = entry.leftIndex { newRight.append(result.leftLines[l]) }
                // entry.leftIndex == nil (a pure `.inserted` entry inside this hunk): left has
                // nothing here, so right contributes nothing either after taking left.
            } else if let r = entry.rightIndex {
                newRight.append(result.rightLines[r])
            }
            // entry not in hunk and rightIndex == nil (a `.removed` entry elsewhere): right never
            // had this line; nothing to contribute.
        }
        return HunkApplyResult(leftLines: result.leftLines, rightLines: newRight)

    case .takeRight:
        // Left adopts right's content for this hunk; right is untouched.
        var newLeft: [String] = []
        newLeft.reserveCapacity(result.leftLines.count)
        for entry in result.entries {
            if hunkEntries.contains(entry) {
                if let r = entry.rightIndex { newLeft.append(result.rightLines[r]) }
            } else if let l = entry.leftIndex {
                newLeft.append(result.leftLines[l])
            }
        }
        return HunkApplyResult(leftLines: newLeft, rightLines: result.rightLines)
    }
}
