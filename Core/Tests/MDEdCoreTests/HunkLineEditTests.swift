import Foundation
import Testing
@testable import MDEdCore

@Suite("HunkLineEdit")
struct HunkLineEditTests {

    /// Applies a `TextEdit` to `text` the same way `NSTextView.insertText(_:replacementRange:)`
    /// would, so these tests exercise exactly what the app does with the result.
    private func apply(_ edit: TextEdit, to text: String) -> String {
        let ns = text as NSString
        return ns.replacingCharacters(in: edit.range.nsRange, with: edit.replacementText)
    }

    @Test func changedHunkTargetsExactExistingRange() {
        let left = ["a", "OLD", "c"]
        let right = ["a", "NEW", "c"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]

        let edit = lineEdit(for: hunk, in: result, direction: .takeLeft)
        #expect(edit.targetLineRange == 1..<2)
        #expect(edit.replacementLines == ["OLD"])

        let rightText = right.joined(separator: "\n")
        let textEditResult = textEdit(for: edit, in: DocumentLines(rightText))
        #expect(apply(textEditResult, to: rightText) == left.joined(separator: "\n"))
    }

    @Test func pureInsertionTakeLeftDeletesTheInsertedLineFromRight() {
        let left = ["a", "b"]
        let right = ["a", "NEW", "b"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]

        let edit = lineEdit(for: hunk, in: result, direction: .takeLeft)
        // The "NEW" line does exist on the right (that's exactly what's being deleted), so the
        // target range is the existing line, not an insertion point.
        #expect(edit.targetLineRange == 1..<2)
        #expect(edit.replacementLines == [])

        let rightText = right.joined(separator: "\n")
        let textEditResult = textEdit(for: edit, in: DocumentLines(rightText))
        #expect(apply(textEditResult, to: rightText) == left.joined(separator: "\n"))
    }

    @Test func pureInsertionTakeRightInsertsIntoLeftAtCorrectSpot() {
        let left = ["a", "b"]
        let right = ["a", "NEW", "b"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]

        let edit = lineEdit(for: hunk, in: result, direction: .takeRight)
        // Insertion point is line index 1 (before "b") on the left.
        #expect(edit.targetLineRange == 1..<1)
        #expect(edit.replacementLines == ["NEW"])

        let leftText = left.joined(separator: "\n")
        let textEditResult = textEdit(for: edit, in: DocumentLines(leftText))
        #expect(apply(textEditResult, to: leftText) == right.joined(separator: "\n"))
    }

    @Test func pureInsertionAtEndOfDocument() {
        let left = ["a", "b"]
        let right = ["a", "b", "TAIL"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]

        let edit = lineEdit(for: hunk, in: result, direction: .takeRight)
        #expect(edit.targetLineRange == 2..<2) // after the last line

        let leftText = left.joined(separator: "\n")
        let textEditResult = textEdit(for: edit, in: DocumentLines(leftText))
        #expect(apply(textEditResult, to: leftText) == right.joined(separator: "\n"))
    }

    @Test func pureInsertionAtStartOfDocument() {
        let left = ["b", "c"]
        let right = ["HEAD", "b", "c"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]

        let edit = lineEdit(for: hunk, in: result, direction: .takeRight)
        #expect(edit.targetLineRange == 0..<0)

        let leftText = left.joined(separator: "\n")
        let textEditResult = textEdit(for: edit, in: DocumentLines(leftText))
        #expect(apply(textEditResult, to: leftText) == right.joined(separator: "\n"))
    }

    @Test func pureRemovalTakeLeftInsertsIntoRight() {
        let left = ["a", "GONE", "b"]
        let right = ["a", "b"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]

        let edit = lineEdit(for: hunk, in: result, direction: .takeLeft)
        #expect(edit.targetLineRange == 1..<1)
        #expect(edit.replacementLines == ["GONE"])

        let rightText = right.joined(separator: "\n")
        let textEditResult = textEdit(for: edit, in: DocumentLines(rightText))
        #expect(apply(textEditResult, to: rightText) == left.joined(separator: "\n"))
    }

    @Test func pureRemovalTakeRightDeletesFromLeft() {
        let left = ["a", "GONE", "b"]
        let right = ["a", "b"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]

        let edit = lineEdit(for: hunk, in: result, direction: .takeRight)
        #expect(edit.targetLineRange == 1..<2)
        #expect(edit.replacementLines == [])

        let leftText = left.joined(separator: "\n")
        let textEditResult = textEdit(for: edit, in: DocumentLines(leftText))
        #expect(apply(textEditResult, to: leftText) == right.joined(separator: "\n"))
    }

    @Test func multiLineChangedHunkReplacesWholeSpan() {
        let left = ["a", "one", "two", "three", "e"]
        let right = ["a", "ONE", "TWO", "e"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]

        let edit = lineEdit(for: hunk, in: result, direction: .takeLeft)
        let rightText = right.joined(separator: "\n")
        let textEditResult = textEdit(for: edit, in: DocumentLines(rightText))
        #expect(apply(textEditResult, to: rightText) == left.joined(separator: "\n"))
    }

    @Test func deletingTheLastLineLeavesNoBlankLineBehind() {
        let left = ["a", "b", "GONE"]
        let right = ["a", "b"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]

        // takeRight: left adopts right's (nonexistent) content for this hunk — i.e. "GONE" is
        // deleted from left.
        let edit = lineEdit(for: hunk, in: result, direction: .takeRight)
        #expect(edit.targetLineRange == 2..<3)
        #expect(edit.replacementLines == [])

        let leftText = left.joined(separator: "\n")
        let textEditResult = textEdit(for: edit, in: DocumentLines(leftText))
        #expect(apply(textEditResult, to: leftText) == right.joined(separator: "\n"))
    }

    @Test func replacingTheLastLineGluesALeadingNewline() {
        let left = ["a", "b", "OLDLAST"]
        let right = ["a", "b", "NEWLAST"]
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]

        let edit = lineEdit(for: hunk, in: result, direction: .takeLeft)
        let rightText = right.joined(separator: "\n")
        let textEditResult = textEdit(for: edit, in: DocumentLines(rightText))
        #expect(apply(textEditResult, to: rightText) == left.joined(separator: "\n"))
    }

    @Test func replacingTheEntireDocumentHasNoStrayNewlines() {
        let left = ["only", "left", "lines"]
        let right = ["totally", "different"]
        let result = diffLines(left, right)
        #expect(hunks(in: result).count == 1)
        let hunk = hunks(in: result)[0]

        let edit = lineEdit(for: hunk, in: result, direction: .takeLeft)
        #expect(edit.targetLineRange == 0..<2)
        let rightText = right.joined(separator: "\n")
        let textEditResult = textEdit(for: edit, in: DocumentLines(rightText))
        #expect(apply(textEditResult, to: rightText) == left.joined(separator: "\n"))
    }

    @Test func editIsLocalizedNotWholeDocument() {
        // The edit's range should be small — scoped to the hunk — not the whole document, even
        // for a large document with one small change far from the edges.
        var left = (0..<200).map { "line \($0)" }
        var right = left
        left[100] = "OLD"
        right[100] = "NEW"
        let result = diffLines(left, right)
        let hunk = hunks(in: result)[0]
        let edit = lineEdit(for: hunk, in: result, direction: .takeLeft)
        let rightText = right.joined(separator: "\n")
        let textEditResult = textEdit(for: edit, in: DocumentLines(rightText))
        // Well short of the full document's length.
        #expect(textEditResult.range.length < 20)
        #expect(apply(textEditResult, to: rightText) == left.joined(separator: "\n"))
    }
}
