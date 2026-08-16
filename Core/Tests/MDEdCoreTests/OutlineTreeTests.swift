import Foundation
import Testing
@testable import MDEdCore

@Suite("OutlineTree")
struct OutlineTreeTests {

    private func entry(_ level: Int, _ title: String, at offset: Int = 0) -> TOCEntry {
        TOCEntry(level: level, title: title, slug: title.lowercased(), range: TextRange(lowerBound: offset, upperBound: offset + 1))
    }

    // MARK: - build(from:)

    @Test func emptyEntriesProducesEmptyTree() {
        #expect(OutlineTree.build(from: []).isEmpty)
    }

    @Test func flatEntriesOfTheSameLevelAreAllSiblingsAtTheRoot() {
        let entries = [entry(2, "A"), entry(2, "B"), entry(2, "C")]
        let tree = OutlineTree.build(from: entries)
        #expect(tree.count == 3)
        #expect(tree.allSatisfy { $0.children.isEmpty })
        #expect(tree.map(\.entry.title) == ["A", "B", "C"])
    }

    @Test func deeperHeadingNestsUnderThePrecedingShallowerOne() {
        let entries = [entry(1, "Title"), entry(2, "Section"), entry(3, "Subsection")]
        let tree = OutlineTree.build(from: entries)
        #expect(tree.count == 1)
        #expect(tree[0].entry.title == "Title")
        #expect(tree[0].children.count == 1)
        #expect(tree[0].children[0].entry.title == "Section")
        #expect(tree[0].children[0].children.count == 1)
        #expect(tree[0].children[0].children[0].entry.title == "Subsection")
    }

    @Test func sameOrShallowerLevelClosesOpenAncestors() {
        // # Title / ## A / ### A1 / ## B  — B is a sibling of A under Title, not nested under A1 or A.
        let entries = [entry(1, "Title"), entry(2, "A"), entry(3, "A1"), entry(2, "B")]
        let tree = OutlineTree.build(from: entries)
        #expect(tree.count == 1)
        let children = tree[0].children
        #expect(children.map(\.entry.title) == ["A", "B"])
        #expect(children[0].children.map(\.entry.title) == ["A1"])
        #expect(children[1].children.isEmpty)
    }

    @Test func skippedLevelStillNestsUnderTheNearestShallowerAncestor() {
        // # Title / ### Deep — no ## in between; Deep still nests one level under Title, not left
        // stranded at the root for want of an intermediate ## that was never there.
        let entries = [entry(1, "Title"), entry(3, "Deep")]
        let tree = OutlineTree.build(from: entries)
        #expect(tree.count == 1)
        #expect(tree[0].children.count == 1)
        #expect(tree[0].children[0].entry.title == "Deep")
    }

    @Test func documentStartingBelowLevelOneStillRootsCorrectly() {
        // Document starts at ## — no # ancestor exists, so ## entries are themselves roots.
        let entries = [entry(2, "A"), entry(3, "A1"), entry(2, "B")]
        let tree = OutlineTree.build(from: entries)
        #expect(tree.map(\.entry.title) == ["A", "B"])
        #expect(tree[0].children.map(\.entry.title) == ["A1"])
    }

    @Test func entryIndexTracksPositionInTheOriginalFlatList() {
        let entries = [entry(1, "Title"), entry(2, "Section"), entry(3, "Subsection")]
        let tree = OutlineTree.build(from: entries)
        #expect(tree[0].entryIndex == 0)
        #expect(tree[0].children[0].entryIndex == 1)
        #expect(tree[0].children[0].children[0].entryIndex == 2)
    }

    // MARK: - containingEntryIndex(in:caretOffset:)

    @Test func emptyDocumentHasNoContainingEntry() {
        #expect(OutlineTree.containingEntryIndex(in: [], caretOffset: 0) == nil)
    }

    @Test func caretBeforeTheFirstHeadingHasNoContainingEntry() {
        let entries = [entry(1, "Title", at: 20)]
        #expect(OutlineTree.containingEntryIndex(in: entries, caretOffset: 0) == nil)
        #expect(OutlineTree.containingEntryIndex(in: entries, caretOffset: 19) == nil)
    }

    @Test func caretExactlyOnAHeadingLineMapsToThatHeading() {
        let entries = [entry(1, "Title", at: 0), entry(2, "Section", at: 20)]
        // Offset 20 is `entries[1]`'s own range.lowerBound.
        #expect(OutlineTree.containingEntryIndex(in: entries, caretOffset: 20) == 1)
    }

    @Test func caretInTheLastSectionMapsToTheLastEntry() {
        let entries = [entry(1, "Title", at: 0), entry(2, "Section", at: 20), entry(2, "Last", at: 50)]
        #expect(OutlineTree.containingEntryIndex(in: entries, caretOffset: 500) == 2)
    }

    @Test func caretInAnEarlierSectionsBodyTextMapsToThatSectionsHeading() {
        let entries = [entry(1, "Title", at: 0), entry(2, "A", at: 20), entry(2, "B", at: 60)]
        // Offset 40 is body text belonging to "A" (between A's heading at 20 and B's at 60).
        #expect(OutlineTree.containingEntryIndex(in: entries, caretOffset: 40) == 1)
    }

    @Test func singleHeadingDocumentMapsEveryOffsetAtOrAfterItToThatHeading() {
        let entries = [entry(1, "Only", at: 5)]
        #expect(OutlineTree.containingEntryIndex(in: entries, caretOffset: 4) == nil)
        #expect(OutlineTree.containingEntryIndex(in: entries, caretOffset: 5) == 0)
        #expect(OutlineTree.containingEntryIndex(in: entries, caretOffset: 10_000) == 0)
    }
}
