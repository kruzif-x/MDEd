/// A contiguous run of non-`.unchanged` diff entries, grouped together with the ranges of lines
/// they span on each side.
///
/// This is the unit "jump to next change" and "take left"/"take right" operate on: a hunk is one
/// indivisible block of difference between the two documents. Two hunks are never adjacent
/// without at least one `.unchanged` entry between them — if they were, they'd be the same hunk.
public struct Hunk: Sendable, Equatable {
    /// The entries (in document order) that make up this hunk. Every entry's `kind` is
    /// `.removed`, `.inserted`, or `.changed` — never `.unchanged`.
    public let entries: [LineDiffEntry]

    /// The range of `leftLines` indices touched by this hunk (removed or changed lines).
    /// `nil` when the hunk is a pure insertion and touches no left-side lines.
    public let leftRange: Range<Int>?

    /// The range of `rightLines` indices touched by this hunk (inserted or changed lines).
    /// `nil` when the hunk is a pure removal and touches no right-side lines.
    public let rightRange: Range<Int>?

    public init(entries: [LineDiffEntry], leftRange: Range<Int>?, rightRange: Range<Int>?) {
        self.entries = entries
        self.leftRange = leftRange
        self.rightRange = rightRange
    }
}

/// Groups a diff's entries into hunks: maximal contiguous runs of non-`.unchanged` entries.
///
/// - Complexity: `O(n)` in the number of diff entries.
public func hunks(in result: LineDiffResult) -> [Hunk] {
    var hunks: [Hunk] = []
    var currentEntries: [LineDiffEntry] = []
    var leftIndices: [Int] = []
    var rightIndices: [Int] = []

    func flush() {
        guard !currentEntries.isEmpty else { return }
        let leftRange: Range<Int>? = leftIndices.isEmpty ? nil : (leftIndices.min()!..<(leftIndices.max()! + 1))
        let rightRange: Range<Int>? = rightIndices.isEmpty ? nil : (rightIndices.min()!..<(rightIndices.max()! + 1))
        hunks.append(Hunk(entries: currentEntries, leftRange: leftRange, rightRange: rightRange))
        currentEntries = []
        leftIndices = []
        rightIndices = []
    }

    for entry in result.entries {
        if entry.kind == .unchanged {
            flush()
            continue
        }
        currentEntries.append(entry)
        if let leftIndex = entry.leftIndex { leftIndices.append(leftIndex) }
        if let rightIndex = entry.rightIndex { rightIndices.append(rightIndex) }
    }
    flush()

    return hunks
}
