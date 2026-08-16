import Testing
@testable import MDEdCore

@Suite("DiffPromptBuilder")
struct DiffPromptBuilderTests {

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    @Test func noHunksProducesNoChunks() {
        let left = DocumentLines("same\ntext")
        let right = DocumentLines("same\ntext")
        let result = diffLines(left.lines, right.lines)
        #expect(hunks(in: result).isEmpty)
        #expect(DiffPromptBuilder.chunk([], left: left, right: right, budgetTokens: 100).isEmpty)
    }

    @Test func renderIncludesHeaderAndBothSidesOfAChange() {
        let left = DocumentLines("keep\nold line\nkeep2")
        let right = DocumentLines("keep\nnew line\nkeep2")
        let result = diffLines(left.lines, right.lines)
        let rendered = DiffPromptBuilder.renderHunks(hunks(in: result), left: left, right: right)
        #expect(rendered.contains("@@"))
        #expect(rendered.contains("- old line"))
        #expect(rendered.contains("+ new line"))
        #expect(!rendered.contains("keep")) // unchanged lines aren't part of any hunk
    }

    /// The central design point of Stage 4's diff summary: rendering *hunks* keeps the prompt
    /// bounded by how much changed, not by how large either document is. Two huge, mostly-identical
    /// documents that differ by only a couple of lines should still produce one small chunk here —
    /// where feeding both full documents as the prompt would blow the budget outright.
    @Test func tinyChangeInHugeDocumentsStaysWithinASmallBudget() {
        let sharedLines = (0..<5000).map { "shared paragraph line \($0) with some ordinary prose text in it" }
        var leftLines = sharedLines
        var rightLines = sharedLines
        leftLines[2500] = "this line will be removed"
        rightLines[2500] = "this line got changed instead"

        let left = DocumentLines(leftLines.joined(separator: "\n"))
        let right = DocumentLines(rightLines.joined(separator: "\n"))
        let result = diffLines(left.lines, right.lines)
        let theHunks = hunks(in: result)
        #expect(theHunks.count == 1)

        // Feeding both full documents would be tens of thousands of tokens; the hunk-based prompt
        // should be tiny by comparison — comfortably a single chunk well under the real budget.
        let chunks = DiffPromptBuilder.chunk(theHunks, left: left, right: right, budgetTokens: TokenEstimator.defaultChunkBudget)
        #expect(chunks.count == 1)
        #expect(TokenEstimator.estimate(chunks[0]) < 200)
    }

    @Test func manyLargeHunksSplitIntoMultipleBudgetFittingChunks() {
        // A genuinely large diff (many separate hunks with real distance between them) should still
        // chunk cleanly, each chunk fitting the budget, rather than growing one giant prompt.
        var leftLines: [String] = []
        var rightLines: [String] = []
        for i in 0..<200 {
            leftLines.append("stable line \(i)")
            leftLines.append("stable line \(i)")
            rightLines.append("stable line \(i)")
            rightLines.append("stable line \(i)")
            leftLines.append("changed content block \(i) with several words of context around it")
            rightLines.append("different content block \(i) with several other words around it instead")
        }
        let left = DocumentLines(leftLines.joined(separator: "\n"))
        let right = DocumentLines(rightLines.joined(separator: "\n"))
        let result = diffLines(left.lines, right.lines)
        let theHunks = hunks(in: result)
        #expect(theHunks.count > 50)

        let chunks = DiffPromptBuilder.chunk(theHunks, left: left, right: right, budgetTokens: 50, estimator: wordCount)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(wordCount(chunk) <= 50)
        }
    }

    @Test func chunkedHunkTextCoversEveryChangedLine() {
        var leftLines: [String] = []
        var rightLines: [String] = []
        for i in 0..<30 {
            leftLines.append("context \(i)")
            rightLines.append("context \(i)")
            leftLines.append("removed \(i)")
            rightLines.append("added \(i)")
        }
        let left = DocumentLines(leftLines.joined(separator: "\n"))
        let right = DocumentLines(rightLines.joined(separator: "\n"))
        let result = diffLines(left.lines, right.lines)
        let theHunks = hunks(in: result)

        let chunks = DiffPromptBuilder.chunk(theHunks, left: left, right: right, budgetTokens: 20, estimator: wordCount)
        let combined = chunks.joined(separator: " ")
        for i in 0..<30 {
            #expect(combined.contains("removed \(i)"))
            #expect(combined.contains("added \(i)"))
        }
    }
}
