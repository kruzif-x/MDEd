import Testing
@testable import MDEdCore

@Suite("HunkApply")
struct HunkApplyTests {

    @Test func takeLeftOverwritesChangedLineOnRight() {
        let left = ["a", "OLD", "c"]
        let right = ["a", "NEW", "c"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]
        let applied = applying(hunk, to: result, direction: .takeLeft)
        #expect(applied.rightLines == ["a", "OLD", "c"])
        #expect(applied.leftLines == left) // untouched
    }

    @Test func takeRightOverwritesChangedLineOnLeft() {
        let left = ["a", "OLD", "c"]
        let right = ["a", "NEW", "c"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]
        let applied = applying(hunk, to: result, direction: .takeRight)
        #expect(applied.leftLines == ["a", "NEW", "c"])
        #expect(applied.rightLines == right) // untouched
    }

    @Test func takeLeftOnPureInsertionRemovesItFromRight() {
        // right has an extra line left doesn't; take-left should delete it from right.
        let left = ["a", "b"]
        let right = ["a", "NEW", "b"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]
        let applied = applying(hunk, to: result, direction: .takeLeft)
        #expect(applied.rightLines == ["a", "b"])
    }

    @Test func takeRightOnPureInsertionAddsItToLeft() {
        let left = ["a", "b"]
        let right = ["a", "NEW", "b"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]
        let applied = applying(hunk, to: result, direction: .takeRight)
        #expect(applied.leftLines == ["a", "NEW", "b"])
    }

    @Test func takeLeftOnPureRemovalAddsItToRight() {
        // left has an extra line right doesn't; take-left should add it to right.
        let left = ["a", "GONE", "b"]
        let right = ["a", "b"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]
        let applied = applying(hunk, to: result, direction: .takeLeft)
        #expect(applied.rightLines == ["a", "GONE", "b"])
    }

    @Test func takeRightOnPureRemovalRemovesItFromLeft() {
        let left = ["a", "GONE", "b"]
        let right = ["a", "b"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]
        let applied = applying(hunk, to: result, direction: .takeRight)
        #expect(applied.leftLines == ["a", "b"])
    }

    @Test func applyingOneHunkLeavesOtherHunksAlone() {
        let left = ["a", "b", "c", "d", "e"]
        let right = ["a", "X", "Y", "d", "Z"]
        let result = diffLines(left, right)
        let grouped = hunks(in: result)
        #expect(grouped.count == 2)

        let appliedFirst = applying(grouped[0], to: result, direction: .takeLeft)
        // First hunk (b,c -> X,Y) taken left: right becomes a,b,c,d,Z — second hunk (e->Z) intact.
        #expect(appliedFirst.rightLines == ["a", "b", "c", "d", "Z"])
    }

    @Test func takingLeftThenRightRoundTripsToOriginalRight() {
        let left = ["alpha", "beta", "gamma"]
        let right = ["alpha", "BETA", "gamma"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]

        let afterTakeLeft = applying(hunk, to: result, direction: .takeLeft)
        #expect(afterTakeLeft.rightLines == left)

        // Re-diff the post-take-left state against the original right, and take-right to restore.
        let secondResult = diffLines(afterTakeLeft.rightLines, right)
        for secondHunk in hunks(in: secondResult) {
            let restored = applying(secondHunk, to: secondResult, direction: .takeRight)
            #expect(restored.leftLines == right)
        }
    }

    @Test func mixedHunkOfChangedAndInsertedLinesTakeLeft() {
        // A hunk that pairs a .changed line with a trailing pure-insertion in the same run.
        let left = ["a", "OLD", "c"]
        let right = ["a", "NEW", "EXTRA", "c"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]
        #expect(hunk.entries.count == 2) // .changed + .inserted
        let applied = applying(hunk, to: result, direction: .takeLeft)
        #expect(applied.rightLines == ["a", "OLD", "c"])
    }
}
