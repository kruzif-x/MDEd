/// The classification of a single row in an aligned line-by-line diff.
public enum LineDiffKind: Sendable, Equatable, Hashable {
    /// The line is identical on both sides.
    case unchanged
    /// The line exists only on the left (the "before"/A side).
    case removed
    /// The line exists only on the right (the "after"/B side).
    case inserted
    /// A line on the left was replaced by a line at the same logical position on the right.
    ///
    /// This is not something `CollectionDifference` reports directly — it only knows about
    /// removals and insertions. `changed` is MDEdCore's synthesis of a removal immediately
    /// followed (in the edit script) by an insertion, treated as one paired edit instead of two
    /// unrelated ones. See `diffLines(_:_:)` for the pairing heuristic.
    case changed
}

/// One row of an aligned line-by-line diff between two documents, referred to below as "left"
/// (the "before"/A document) and "right" (the "after"/B document).
///
/// `leftIndex` and `rightIndex` are indices into the original `left`/`right` line arrays passed
/// to `diffLines(_:_:)`. Exactly one of them is `nil` for `.removed` (no `rightIndex`) and
/// `.inserted` (no `leftIndex`) entries; both are present for `.unchanged` and `.changed`.
public struct LineDiffEntry: Sendable, Equatable, Hashable {
    public let kind: LineDiffKind
    public let leftIndex: Int?
    public let rightIndex: Int?

    public init(kind: LineDiffKind, leftIndex: Int?, rightIndex: Int?) {
        self.kind = kind
        self.leftIndex = leftIndex
        self.rightIndex = rightIndex
    }
}

/// The result of diffing two documents' lines against each other.
///
/// `entries` is ordered so that walking it in order and, for each entry, looking at whichever of
/// `leftIndex`/`rightIndex` is present, visits `leftLines` and `rightLines` each in their own
/// increasing order — i.e. it is a valid alignment/merge of the two line sequences, suitable for
/// driving a side-by-side view directly.
public struct LineDiffResult: Sendable, Equatable {
    public let leftLines: [String]
    public let rightLines: [String]
    public let entries: [LineDiffEntry]

    public init(leftLines: [String], rightLines: [String], entries: [LineDiffEntry]) {
        self.leftLines = leftLines
        self.rightLines = rightLines
        self.entries = entries
    }
}

/// Computes a line-level diff between `left` and `right` using the standard library's
/// `CollectionDifference` (a Myers-algorithm diff over `Equatable` collections — see
/// `Array.difference(from:)`).
///
/// `CollectionDifference` only ever reports `.remove` and `.insert` steps. This function adds one
/// thing on top: it recognizes when a maximal run of removals is immediately followed by a
/// maximal run of insertions at the same edit-script position (or vice versa) — the shape a
/// same-spot line replacement takes — and pairs them off index-by-index as `.changed` entries.
/// Any unpaired leftover in the longer of the two runs remains `.removed`/`.inserted`. This is a
/// local, position-based heuristic; it says nothing about *content* similarity between the paired
/// lines (a completely rewritten line still shows as one `.changed` entry, not a `.removed`
/// entry next to an unrelated `.inserted` one), which is what makes "take left"/"take right" and
/// word-level highlighting operate on a single coherent unit instead of two.
///
/// - Complexity: `O((left.count + right.count) * D)` where `D` is the size of the edit script,
///   inherited from `CollectionDifference`; the pairing pass afterwards is linear in the number
///   of diff steps.
public func diffLines(_ left: [String], _ right: [String]) -> LineDiffResult {
    let difference = right.difference(from: left)

    // CollectionDifference reports removals against `left`'s original indices and insertions
    // against `right`'s *final* indices; both are unordered within the `.removals`/`.insertions`
    // arrays in general, so sort each by offset to walk them in document order.
    let removals = difference.removals.sorted { $0.offset < $1.offset }
    let insertions = difference.insertions.sorted { $0.offset < $1.offset }

    var entries: [LineDiffEntry] = []
    entries.reserveCapacity(left.count + right.count)

    var removalIndex = 0
    var insertionIndex = 0
    var leftCursor = 0
    var rightCursor = 0

    while leftCursor < left.count || rightCursor < right.count {
        let nextRemovalOffset = removalIndex < removals.count ? removals[removalIndex].offset : Int.max
        let nextInsertionOffset = insertionIndex < insertions.count ? insertions[insertionIndex].offset : Int.max

        if leftCursor == nextRemovalOffset || rightCursor == nextInsertionOffset {
            // We're at the start of an edit: gather the whole contiguous run of removals here
            // and the whole contiguous run of insertions here, then pair them off.
            var removedRun: [Int] = []
            while removalIndex < removals.count, removals[removalIndex].offset == leftCursor + removedRun.count {
                removedRun.append(leftCursor + removedRun.count)
                removalIndex += 1
            }
            var insertedRun: [Int] = []
            while insertionIndex < insertions.count, insertions[insertionIndex].offset == rightCursor + insertedRun.count {
                insertedRun.append(rightCursor + insertedRun.count)
                insertionIndex += 1
            }

            let pairedCount = min(removedRun.count, insertedRun.count)
            for i in 0..<pairedCount {
                entries.append(LineDiffEntry(kind: .changed, leftIndex: removedRun[i], rightIndex: insertedRun[i]))
            }
            for i in pairedCount..<removedRun.count {
                entries.append(LineDiffEntry(kind: .removed, leftIndex: removedRun[i], rightIndex: nil))
            }
            for i in pairedCount..<insertedRun.count {
                entries.append(LineDiffEntry(kind: .inserted, leftIndex: nil, rightIndex: insertedRun[i]))
            }

            leftCursor += removedRun.count
            rightCursor += insertedRun.count
        } else {
            // Unchanged line: present, unmodified, on both sides.
            entries.append(LineDiffEntry(kind: .unchanged, leftIndex: leftCursor, rightIndex: rightCursor))
            leftCursor += 1
            rightCursor += 1
        }
    }

    return LineDiffResult(leftLines: left, rightLines: right, entries: entries)
}
