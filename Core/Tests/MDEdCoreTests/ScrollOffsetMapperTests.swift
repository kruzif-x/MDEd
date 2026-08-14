import Testing
@testable import MDEdCore

@Suite("ScrollOffsetMapper")
struct ScrollOffsetMapperTests {

    @Test func identicalDocumentsUniformHeightIsIdentityMapping() {
        let lines = (0..<20).map { "line \($0)" }
        let alignment = LineAlignmentMap(diffLines(lines, lines))
        let heights = Array(repeating: 20.0, count: 20)
        let mapper = ScrollOffsetMapper(alignment: alignment, leftLineHeights: heights, rightLineHeights: heights)

        for offset in stride(from: 0.0, through: 400.0, by: 37.0) {
            #expect(abs(mapper.rightOffset(forLeftOffset: offset) - offset) < 0.01)
        }
    }

    @Test func boundariesMapToBoundaries() {
        let left = (0..<10).map { "l\($0)" }
        let right = (0..<15).map { "r\($0)" }
        let alignment = LineAlignmentMap(diffLines(left, right))
        let leftHeights = Array(repeating: 10.0, count: 10)
        let rightHeights = Array(repeating: 10.0, count: 15)
        let mapper = ScrollOffsetMapper(alignment: alignment, leftLineHeights: leftHeights, rightLineHeights: rightHeights)

        #expect(mapper.rightOffset(forLeftOffset: 0) == 0)
        #expect(abs(mapper.rightOffset(forLeftOffset: 100) - 150) < 0.01) // full left height -> full right height
        #expect(mapper.leftOffset(forRightOffset: 0) == 0)
        #expect(abs(mapper.leftOffset(forRightOffset: 150) - 100) < 0.01)
    }

    @Test func variableLineHeightsAreRespected() {
        // Two identical documents but the left renders each line twice as tall as the right
        // (e.g. a larger font pane). A given left offset should land at half that offset on the
        // right, since alignment is 1:1 per line.
        let lines = (0..<5).map { "line \($0)" }
        let alignment = LineAlignmentMap(diffLines(lines, lines))
        let leftHeights = Array(repeating: 40.0, count: 5)
        let rightHeights = Array(repeating: 20.0, count: 5)
        let mapper = ScrollOffsetMapper(alignment: alignment, leftLineHeights: leftHeights, rightLineHeights: rightHeights)

        #expect(abs(mapper.rightOffset(forLeftOffset: 80) - 40) < 0.01) // 2 lines down on the left -> 2 lines down on the right
        #expect(abs(mapper.rightOffset(forLeftOffset: 40) - 20) < 0.01)
    }

    @Test func fractionalPositionInterpolatesAcrossAnInsertedRegion() {
        // left: [a, b]; right: [a, X, Y, Z, b] — a run of pure insertions between two anchors.
        let left = ["a", "b"]
        let right = ["a", "X", "Y", "Z", "b"]
        let alignment = LineAlignmentMap(diffLines(left, right))
        let leftHeights = [10.0, 10.0]
        let rightHeights = [10.0, 10.0, 10.0, 10.0, 10.0]
        let mapper = ScrollOffsetMapper(alignment: alignment, leftLineHeights: leftHeights, rightLineHeights: rightHeights)

        // Halfway down left line 0 (offset 5, i.e. fractional line 0.5) should map to fractional
        // right line 2.0 (per LineAlignmentMap's own documented example), i.e. offset 20.
        #expect(abs(mapper.rightOffset(forLeftOffset: 5) - 20) < 0.01)
    }

    @Test func emptyDocumentsMapToZero() {
        let alignment = LineAlignmentMap(diffLines([], []))
        let mapper = ScrollOffsetMapper(alignment: alignment, leftLineHeights: [], rightLineHeights: [])
        #expect(mapper.rightOffset(forLeftOffset: 0) == 0)
        #expect(mapper.leftOffset(forRightOffset: 0) == 0)
    }

    @Test func monotonicNonDecreasingAsLeftOffsetIncreases() {
        let left = ["a", "b", "c", "d", "e", "f", "g"]
        let right = ["a", "X", "b", "Y", "Z", "c", "d", "e", "f", "g"]
        let alignment = LineAlignmentMap(diffLines(left, right))
        let leftHeights = (0..<left.count).map { Double(15 + ($0 % 3) * 5) }
        let rightHeights = (0..<right.count).map { Double(12 + ($0 % 4) * 7) }
        let mapper = ScrollOffsetMapper(alignment: alignment, leftLineHeights: leftHeights, rightLineHeights: rightHeights)

        let totalLeftHeight = leftHeights.reduce(0, +)
        var previous = -1.0
        var offset = 0.0
        while offset <= totalLeftHeight {
            let mapped = mapper.rightOffset(forLeftOffset: offset)
            #expect(mapped >= previous - 0.001)
            previous = mapped
            offset += 3.7
        }
    }

    @Test func offsetPastEndClampsToDocumentEnd() {
        let lines = (0..<5).map { "line \($0)" }
        let alignment = LineAlignmentMap(diffLines(lines, lines))
        let heights = Array(repeating: 20.0, count: 5)
        let mapper = ScrollOffsetMapper(alignment: alignment, leftLineHeights: heights, rightLineHeights: heights)
        #expect(abs(mapper.rightOffset(forLeftOffset: 10_000) - 100) < 0.01)
        #expect(abs(mapper.rightOffset(forLeftOffset: -50) - 0) < 0.01)
    }
}
