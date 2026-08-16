import Foundation

/// One node in a heading tree built from a flat `[TOCEntry]` list — the shape an outline sidebar's
/// `NSOutlineView` needs (nested by level), as opposed to `TableOfContents.entries(from:)`'s own
/// flat, document-order list (the shape a rendered bullet list needs). Both are derived from the
/// same `TOCEntry` data; nothing here re-parses anything.
public struct OutlineNode: Sendable, Equatable {
    /// The heading this node represents.
    public let entry: TOCEntry
    /// This node's position in the flat `[TOCEntry]` list `OutlineTree.build(from:)` was given —
    /// carried through so a caller that maps a caret offset to an entry index (see
    /// `OutlineTree.containingEntryIndex(in:caretOffset:)`) can find the matching node without a
    /// second, separate search.
    public let entryIndex: Int
    public var children: [OutlineNode]

    public init(entry: TOCEntry, entryIndex: Int, children: [OutlineNode] = []) {
        self.entry = entry
        self.entryIndex = entryIndex
        self.children = children
    }
}

/// Builds a nested heading tree from a flat entry list, and maps a caret position to the entry it
/// currently sits inside — the two pieces of pure logic an outline sidebar needs beyond what
/// `TableOfContents` already provides. Kept in `MDEdCore`, not the app target, for the same reason
/// every other coordinate-math type here is: it's exhaustively, headlessly testable, and this
/// project's own experience is that app-target logic needs a running app to catch its bugs while
/// package logic doesn't.
public enum OutlineTree {

    /// Nests `entries` by `TOCEntry.level`, in document order. A heading nests under the nearest
    /// *preceding* heading with a strictly lower level, regardless of gaps in the sequence — e.g. a
    /// `###` directly following a `#` (no `##` between them) still nests one level under the `#`,
    /// matching how a reader would expect "everything until the next same-or-shallower heading"
    /// to group, not leaving it stranded at the root for want of an intermediate level that was
    /// never there. A heading whose level is less-than-or-equal to some open ancestor's level closes
    /// that ancestor (and anything nested deeper than it) before finding its own parent.
    public static func build(from entries: [TOCEntry]) -> [OutlineNode] {
        var roots: [Builder] = []
        var stack: [Builder] = []

        for (index, entry) in entries.enumerated() {
            let node = Builder(entry: entry, entryIndex: index)
            while let last = stack.last, last.entry.level >= entry.level {
                stack.removeLast()
            }
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
            stack.append(node)
        }

        return roots.map { $0.freeze() }
    }

    /// The index into `entries` of the heading that UTF-16 offset `caretOffset` currently falls
    /// under — the entry whose section the caret is visually "inside" for outline-highlighting
    /// purposes, not necessarily the entry whose own range contains the offset.
    ///
    /// Returns the last entry (in document order) whose range starts at or before `caretOffset` —
    /// i.e. "the most recent heading the caret has passed." That covers a caret sitting on the
    /// heading line itself (its own entry) exactly as well as a caret anywhere in that section's
    /// body text, all the way up to (but not including) the next heading's own start.
    ///
    /// Returns `nil` when there is no such heading: an empty document, or a caret positioned before
    /// the first heading (the document's un-sectioned preamble, if any).
    public static func containingEntryIndex(in entries: [TOCEntry], caretOffset: Int) -> Int? {
        var result: Int?
        for (index, entry) in entries.enumerated() {
            guard entry.range.lowerBound <= caretOffset else { break }
            result = index
        }
        return result
    }

    /// A mutable staging node used only while `build(from:)` is assembling the tree — `OutlineNode`
    /// itself stays an immutable value type for callers, but growing a tree of value types
    /// bottom-up while walking a flat list top-down is awkward without a mutable intermediate.
    private final class Builder {
        let entry: TOCEntry
        let entryIndex: Int
        var children: [Builder] = []

        init(entry: TOCEntry, entryIndex: Int) {
            self.entry = entry
            self.entryIndex = entryIndex
        }

        func freeze() -> OutlineNode {
            OutlineNode(entry: entry, entryIndex: entryIndex, children: children.map { $0.freeze() })
        }
    }
}
