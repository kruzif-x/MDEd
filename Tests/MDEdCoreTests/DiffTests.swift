import Testing
@testable import MDEdCore

@Suite("LineDiff")
struct LineDiffTests {

    // MARK: Basic edge cases

    @Test func bothEmpty() {
        let result = diffLines([], [])
        #expect(result.entries.isEmpty)
    }

    @Test func leftEmptyRightNonEmpty() {
        let result = diffLines([], ["a", "b"])
        #expect(result.entries.count == 2)
        #expect(result.entries.allSatisfy { $0.kind == .inserted })
        #expect(result.entries.map(\.rightIndex) == [0, 1])
    }

    @Test func leftNonEmptyRightEmpty() {
        let result = diffLines(["a", "b"], [])
        #expect(result.entries.count == 2)
        #expect(result.entries.allSatisfy { $0.kind == .removed })
        #expect(result.entries.map(\.leftIndex) == [0, 1])
    }

    @Test func identicalDocuments() {
        let lines = ["one", "two", "three"]
        let result = diffLines(lines, lines)
        #expect(result.entries.count == 3)
        #expect(result.entries.allSatisfy { $0.kind == .unchanged })
    }

    @Test func entirelyInserted() {
        let result = diffLines([], ["a", "b", "c"])
        #expect(result.entries.allSatisfy { $0.kind == .inserted })
        #expect(result.entries.count == 3)
    }

    @Test func entirelyRemoved() {
        let result = diffLines(["a", "b", "c"], [])
        #expect(result.entries.allSatisfy { $0.kind == .removed })
        #expect(result.entries.count == 3)
    }

    @Test func changeAtVeryFirstLine() {
        let result = diffLines(["OLD", "b", "c"], ["NEW", "b", "c"])
        #expect(result.entries.first?.kind == .changed)
        #expect(result.entries.first?.leftIndex == 0)
        #expect(result.entries.first?.rightIndex == 0)
        #expect(result.entries.dropFirst().allSatisfy { $0.kind == .unchanged })
    }

    @Test func changeAtVeryLastLine() {
        let result = diffLines(["a", "b", "OLD"], ["a", "b", "NEW"])
        #expect(result.entries.last?.kind == .changed)
        #expect(result.entries.last?.leftIndex == 2)
        #expect(result.entries.last?.rightIndex == 2)
        #expect(result.entries.dropLast().allSatisfy { $0.kind == .unchanged })
    }

    @Test func trailingNewlineOnlyDifference() {
        // Modeled as line arrays: a trailing newline means the array has a trailing empty line.
        let left = ["a", "b"]
        let right = ["a", "b", ""]
        let result = diffLines(left, right)
        let nonUnchanged = result.entries.filter { $0.kind != .unchanged }
        #expect(nonUnchanged.count == 1)
        #expect(nonUnchanged.first?.kind == .inserted)
        #expect(nonUnchanged.first?.rightIndex == 2)
    }

    @Test func crlfVersusLFTreatedAsDifferentLines() {
        // MDEdCore diffs pre-split line arrays; how a caller splits CRLF vs LF text is their
        // choice. If they split naively without stripping \r, "a\r" != "a" and the line shows as
        // changed, which is the documented, correct behavior for whatever array was handed in.
        let result = diffLines(["a\r", "b\r"], ["a", "b"])
        #expect(result.entries.allSatisfy { $0.kind == .changed })
    }

    @Test func crlfNormalizedLinesCompareEqual() {
        // If the caller splits on newlines (Swift's `Character.isNewline` treats "\r\n" as one
        // grapheme cluster, so this drops the line-ending entirely rather than leaving a
        // trailing "\r" — the recommended normalization), CRLF vs LF sourced content that's
        // otherwise identical correctly shows no differences.
        let left = "a\r\nb\r\nc".split(whereSeparator: \.isNewline).map(String.init)
        let right = ["a", "b", "c"]
        let result = diffLines(left, right)
        #expect(result.entries.allSatisfy { $0.kind == .unchanged })
    }

    @Test func singleLineChangedInLargeDocument() {
        var left = (0..<500).map { "line \($0)" }
        var right = left
        left[250] = "line 250 ORIGINAL"
        right[250] = "line 250 MODIFIED"
        let result = diffLines(left, right)
        let changes = result.entries.filter { $0.kind != .unchanged }
        #expect(changes.count == 1)
        #expect(changes.first?.kind == .changed)
        #expect(changes.first?.leftIndex == 250)
        #expect(changes.first?.rightIndex == 250)
    }

    @Test func repeatedIdenticalLinesChangeInMiddle() {
        let left = ["A", "A", "A"]
        let right = ["A", "B", "A"]
        let result = diffLines(left, right)
        // Regardless of which specific alignment the underlying Myers diff picks among
        // equally-minimal solutions, applying the entries must reconstruct `right` exactly, and
        // there must be exactly one non-unchanged unit of change (one .changed entry, or a
        // matched removed+inserted pair).
        assertReconstructs(result)
        let changeCount = result.entries.filter { $0.kind != .unchanged }.count
        #expect(changeCount == 2 || changeCount == 1) // one .changed, or a removed+inserted pair
    }

    @Test func manyRepeatedIdenticalLinesNoSpuriousChanges() {
        let left = Array(repeating: "same", count: 50)
        let right = Array(repeating: "same", count: 50)
        let result = diffLines(left, right)
        #expect(result.entries.allSatisfy { $0.kind == .unchanged })
        #expect(result.entries.count == 50)
    }

    @Test func repeatedLinesWithOneInsertion() {
        let left = Array(repeating: "same", count: 10)
        var right = left
        right.insert("NEW", at: 5)
        let result = diffLines(left, right)
        assertReconstructs(result)
        let inserted = result.entries.filter { $0.kind == .inserted }
        #expect(inserted.count == 1)
    }

    // MARK: Reconstruction invariant (applies broadly)

    @Test func reconstructionHoldsForMixedEditScript() {
        let left = ["alpha", "beta", "gamma", "delta", "epsilon"]
        let right = ["alpha", "BETA", "gamma", "zeta", "delta", "epsilon", "omega"]
        let result = diffLines(left, right)
        assertReconstructs(result)
    }

    // MARK: Hunks

    @Test func hunksGroupContiguousChanges() {
        let left = ["a", "b", "c", "d", "e"]
        let right = ["a", "X", "Y", "d", "Z"]
        let result = diffLines(left, right)
        let grouped = hunks(in: result)
        // Two separate change regions: (b,c -> X,Y) and (e -> Z).
        #expect(grouped.count == 2)
        #expect(grouped[0].leftRange == 1..<3)
        #expect(grouped[0].rightRange == 1..<3)
        #expect(grouped[1].leftRange == 4..<5)
        #expect(grouped[1].rightRange == 4..<5)
    }

    @Test func noHunksWhenIdentical() {
        let lines = ["a", "b", "c"]
        #expect(hunks(in: diffLines(lines, lines)).isEmpty)
    }

    @Test func hunkForPureInsertionHasNilLeftRange() {
        let result = diffLines(["a", "b"], ["a", "NEW", "b"])
        let grouped = hunks(in: result)
        #expect(grouped.count == 1)
        #expect(grouped[0].leftRange == nil)
        #expect(grouped[0].rightRange == 1..<2)
    }

    // MARK: Alignment mapping

    @Test func alignmentIdenticalDocumentsIsIdentity() {
        let lines = (0..<20).map { "line \($0)" }
        let map = LineAlignmentMap(diffLines(lines, lines))
        for i in stride(from: 0, to: 20, by: 3) {
            #expect(abs(map.position(ofLeft: Double(i)) - Double(i)) < 0.0001)
        }
    }

    @Test func alignmentBoundaries() {
        let left = (0..<10).map { "l\($0)" }
        let right = (0..<15).map { "r\($0)" }
        let map = LineAlignmentMap(diffLines(left, right))
        #expect(map.position(ofLeft: 0) == 0)
        #expect(map.position(ofLeft: 10) == 15)
        #expect(map.position(ofRight: 0) == 0)
        #expect(map.position(ofRight: 15) == 10)
    }

    @Test func alignmentIsMonotonicNonDecreasing() {
        let left = ["a", "b", "INSERTED_ON_LEFT_ONLY_ISH", "c", "d", "e", "f"]
        let right = ["a", "b", "c", "X", "Y", "Z", "d", "e", "f"]
        let map = LineAlignmentMap(diffLines(left, right))
        var previous = -1.0
        for i in stride(from: 0.0, through: Double(left.count), by: 0.25) {
            let position = map.position(ofLeft: i)
            #expect(position >= previous - 0.0001)
            previous = position
        }
    }

    @Test func alignmentInterpolatesFractionallyAcrossAnInsertion() {
        // left: [a, b]; right: [a, X, Y, Z, b] — a run of 3 pure insertions between two anchors.
        let left = ["a", "b"]
        let right = ["a", "X", "Y", "Z", "b"]
        let map = LineAlignmentMap(diffLines(left, right))
        // Anchors: (0,0) and (1,4). Left position 0.5 should map to right position 2.0.
        #expect(abs(map.position(ofLeft: 0.5) - 2.0) < 0.0001)
    }

    @Test func alignmentRoundTripIsApproximatelyConsistentAtAnchors() {
        let left = ["a", "b", "c", "d"]
        let right = ["a", "X", "b", "c", "Y", "d"]
        let result = diffLines(left, right)
        let map = LineAlignmentMap(result)
        // Every unchanged/changed anchor should map back to itself in both directions.
        for entry in result.entries where entry.kind == .unchanged || entry.kind == .changed {
            guard let l = entry.leftIndex, let r = entry.rightIndex else { continue }
            #expect(abs(map.position(ofLeft: Double(l)) - Double(r)) < 0.0001)
            #expect(abs(map.position(ofRight: Double(r)) - Double(l)) < 0.0001)
        }
    }

    // MARK: Word-level diff

    @Test func wordDiffHighlightsOnlyChangedSpan() {
        let result = diffWords("The quick brown fox", "The slow brown fox")
        let removedWords = result.oldSpans.filter { $0.kind == .removed }.map { String($0.text) }
        let insertedWords = result.newSpans.filter { $0.kind == .inserted }.map { String($0.text) }
        #expect(removedWords == ["quick"])
        #expect(insertedWords == ["slow"])
    }

    @Test func wordDiffSpansTileTheWholeLine() {
        let (old, new) = ("Hello, world!", "Hello, there!")
        let result = diffWords(old, new)
        let reconstructedOld = result.oldSpans.map { String($0.text) }.joined()
        let reconstructedNew = result.newSpans.map { String($0.text) }.joined()
        #expect(reconstructedOld == old)
        #expect(reconstructedNew == new)
    }

    @Test func wordDiffOnIdenticalLinesHasNoChanges() {
        let result = diffWords("same line here", "same line here")
        #expect(result.oldSpans.allSatisfy { $0.kind == .unchanged })
        #expect(result.newSpans.allSatisfy { $0.kind == .unchanged })
    }

    // MARK: Performance

    @Test func performanceOnLargeDocument() {
        let lineCount = 5000
        var left = (0..<lineCount).map { "This is line number \($0) with some representative prose content." }
        var right = left
        // Scatter a realistic number of edits across the document.
        for i in stride(from: 100, to: lineCount, by: 137) {
            right[i] = left[i] + " EDITED"
        }
        right.insert("An inserted line.", at: 42)
        left.removeLast(3)

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let result = diffLines(left, right)
            _ = hunks(in: result)
            _ = LineAlignmentMap(result)
        }
        // Generous bound for a "few thousand lines, every keystroke" target — real interactive
        // use needs this well under 100ms; this asserts a loose upper bound so the test isn't
        // flaky on slower CI hardware while still catching an accidental quadratic blowup.
        #expect(elapsed < .seconds(2))
    }
}

/// Applies a `LineDiffResult`'s entries and asserts the reconstructed sequence, read off
/// `rightLines` via each entry's `rightIndex` (or `leftLines` via `leftIndex` for removals),
/// exactly reproduces `rightLines` and that `leftLines` is exactly recovered by walking removed +
/// unchanged + changed(left side) entries in order. This is the fundamental correctness property
/// of any diff, independent of which specific alignment an implementation chooses among ties.
private func assertReconstructs(_ result: LineDiffResult) {
    var reconstructedRight: [String] = []
    var reconstructedLeft: [String] = []
    for entry in result.entries {
        switch entry.kind {
        case .unchanged, .changed:
            reconstructedLeft.append(result.leftLines[entry.leftIndex!])
            reconstructedRight.append(result.rightLines[entry.rightIndex!])
        case .removed:
            reconstructedLeft.append(result.leftLines[entry.leftIndex!])
        case .inserted:
            reconstructedRight.append(result.rightLines[entry.rightIndex!])
        }
    }
    #expect(reconstructedLeft == result.leftLines)
    #expect(reconstructedRight == result.rightLines)
}
