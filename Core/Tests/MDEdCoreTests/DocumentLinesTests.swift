import Foundation
import Testing
@testable import MDEdCore

@Suite("DocumentLines")
struct DocumentLinesTests {

    @Test func emptyDocumentHasOneEmptyLine() {
        let doc = DocumentLines("")
        #expect(doc.lines == [""])
        #expect(doc.lineRanges == [TextRange(lowerBound: 0, upperBound: 0)])
    }

    @Test func noTrailingNewlineYieldsExactLineCount() {
        let doc = DocumentLines("a\nbb\nccc")
        #expect(doc.lines == ["a", "bb", "ccc"])
    }

    @Test func trailingNewlineYieldsExtraEmptyLastLine() {
        let doc = DocumentLines("a\nb\n")
        #expect(doc.lines == ["a", "b", ""])
    }

    @Test func lineRangesExcludeNewlinesAndAreDisjoint() {
        let text = "one\ntwo\nthree"
        let doc = DocumentLines(text)
        let ns = text as NSString
        for (line, range) in zip(doc.lines, doc.lineRanges) {
            #expect(ns.substring(with: range.nsRange) == line)
        }
    }

    @Test func lineRangesMatchDiffLinesSplitConvention() {
        // The same split diffLines(_:_:) tests use elsewhere: plain "\n" splitting.
        let text = "alpha\nbeta\ngamma"
        let doc = DocumentLines(text)
        #expect(doc.lines == text.components(separatedBy: "\n"))
    }

    @Test func lineIndexAtOffsetFindsContainingLine() {
        let doc = DocumentLines("aa\nbbbb\nc")
        // "aa" -> [0,2), "bbbb" -> [3,7), "c" -> [8,9)
        #expect(doc.lineIndex(atUTF16Offset: 0) == 0)
        #expect(doc.lineIndex(atUTF16Offset: 1) == 0)
        #expect(doc.lineIndex(atUTF16Offset: 3) == 1)
        #expect(doc.lineIndex(atUTF16Offset: 6) == 1)
        #expect(doc.lineIndex(atUTF16Offset: 8) == 2)
        #expect(doc.lineIndex(atUTF16Offset: 9) == 2)
    }

    @Test func lineIndexOutOfRangeReturnsNil() {
        let doc = DocumentLines("abc")
        #expect(doc.lineIndex(atUTF16Offset: -1) == nil)
        #expect(doc.lineIndex(atUTF16Offset: 100) == nil)
    }

    @Test func nonASCIIContentKeepsUTF16Offsets() {
        // "😀" is 2 UTF-16 code units; "文" is 1.
        let doc = DocumentLines("😀ab\n文字")
        #expect(doc.lines == ["😀ab", "文字"])
        #expect(doc.lineRanges[0] == TextRange(lowerBound: 0, upperBound: 4)) // 2 + 1 + 1
        #expect(doc.lineRanges[1] == TextRange(lowerBound: 5, upperBound: 7))
    }
}
