import Foundation
import Testing
@testable import MDEdCore

@Suite("DocumentChunker")
struct DocumentChunkerTests {

    /// One token per whitespace-delimited word — used throughout instead of `TokenEstimator.estimate`
    /// so these tests exercise the chunking *algorithm* with exact, hand-checkable arithmetic,
    /// independent of the real estimator's calibration (which `TokenEstimatorTests` covers on its
    /// own). Chosen deliberately not to special-case CJK, so `cjkDocument...` below still needs the
    /// real estimator to be meaningful.
    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private func words(_ n: Int, prefix: String = "word") -> String {
        (0..<n).map { "\(prefix)\($0)" }.joined(separator: " ")
    }

    // MARK: - Empty input

    @Test func emptyInputProducesNoChunks() {
        #expect(DocumentChunker.chunk("", budgetTokens: 10, estimator: wordCount).isEmpty)
    }

    @Test func whitespaceOnlyInputProducesNoChunks() {
        #expect(DocumentChunker.chunk("   \n\n\t  \n", budgetTokens: 10, estimator: wordCount).isEmpty)
    }

    // MARK: - Fits whole

    @Test func documentAtExactlyBudgetIsOneChunk() {
        let text = words(10)
        let chunks = DocumentChunker.chunk(text, budgetTokens: 10, estimator: wordCount)
        #expect(chunks.count == 1)
        #expect(chunks[0].text == text)
        #expect(chunks[0].estimatedTokens == 10)
    }

    @Test func documentJustUnderBudgetIsOneChunk() {
        let text = words(9)
        let chunks = DocumentChunker.chunk(text, budgetTokens: 10, estimator: wordCount)
        #expect(chunks.count == 1)
        #expect(chunks[0].text == text)
    }

    // MARK: - Just over budget: splits, stays faithful

    @Test func documentJustOverBudgetSplitsAtParagraphs() {
        let paragraphA = words(6, prefix: "a")
        let paragraphB = words(6, prefix: "b")
        let text = "\(paragraphA)\n\n\(paragraphB)" // 12 words total, over a 10-word budget
        let chunks = DocumentChunker.chunk(text, budgetTokens: 10, estimator: wordCount)
        #expect(chunks.count == 2)
        for chunk in chunks {
            #expect(chunk.estimatedTokens <= 10)
        }
        #expect(chunks[0].text.contains("a0"))
        #expect(chunks[1].text.contains("b0"))
    }

    @Test func manySmallParagraphsPackTogetherRatherThanFragmenting() {
        // Five 2-word paragraphs, budget 10: everything fits in one chunk together, so packing
        // should produce exactly one chunk, not five.
        let paragraphs = (0..<5).map { words(2, prefix: "p\($0)-") }.joined(separator: "\n\n")
        let chunks = DocumentChunker.chunk(paragraphs, budgetTokens: 10, estimator: wordCount)
        #expect(chunks.count == 1)
    }

    // MARK: - Heading boundaries take priority over paragraphs

    @Test func splitsAtHeadingBoundariesBeforeParagraphs() {
        let sectionOne = "# Section One\n\n\(words(6, prefix: "a"))"
        let sectionTwo = "# Section Two\n\n\(words(6, prefix: "b"))"
        let text = "\(sectionOne)\n\n\(sectionTwo)"
        let chunks = DocumentChunker.chunk(text, budgetTokens: 10, estimator: wordCount)
        #expect(chunks.count == 2)
        #expect(chunks[0].text.hasPrefix("# Section One"))
        #expect(chunks[1].text.hasPrefix("# Section Two"))
    }

    @Test func oversizedSectionFallsBackToParagraphSplittingWithinItself() {
        // "Big" section alone exceeds budget and has two paragraphs; "Small" section fits on its
        // own. Expect: Small stays one chunk, Big splits into (at least) two.
        let big = "# Big\n\n\(words(6, prefix: "a"))\n\n\(words(6, prefix: "b"))"
        let small = "# Small\n\n\(words(2, prefix: "c"))"
        let text = "\(big)\n\n\(small)"
        let chunks = DocumentChunker.chunk(text, budgetTokens: 10, estimator: wordCount)
        #expect(chunks.count >= 3)
        for chunk in chunks { #expect(chunk.estimatedTokens <= 10) }
        #expect(chunks.last!.text.contains("# Small"))
    }

    // MARK: - The pathological base case: one enormous, unsplittable paragraph

    @Test func enormousUnsplittableParagraphReturnsOneOversizedChunkRatherThanCrashing() {
        // No headings, no blank lines, no sentence-ending punctuation anywhere — nothing this
        // chunker is willing to split on. It must still terminate and return the content whole,
        // not throw, hang, or silently drop text.
        let text = words(50) // 50 tokens against a 10-token budget
        let chunks = DocumentChunker.chunk(text, budgetTokens: 10, estimator: wordCount)
        #expect(chunks.count == 1)
        #expect(chunks[0].text == text)
        #expect(chunks[0].estimatedTokens == 50) // honestly over budget, not silently truncated
    }

    @Test func enormousParagraphWithSentencesSplitsAtSentenceBoundaries() {
        // One paragraph (no blank lines, no headings), but real sentences — this is the case that
        // distinguishes "cannot be split" from "can be split, just not at the paragraph level".
        let sentences = (0..<6).map { "Sentence number \($0) has four words." }
        let text = sentences.joined(separator: " ")
        let chunks = DocumentChunker.chunk(text, budgetTokens: 15, estimator: wordCount)
        #expect(chunks.count > 1)
        for chunk in chunks { #expect(chunk.estimatedTokens <= 15) }
    }

    @Test func neverCutsMidSentence() {
        let sentences = (0..<8).map { "Sentence \($0) ends cleanly here." }
        let text = sentences.joined(separator: " ")
        let chunks = DocumentChunker.chunk(text, budgetTokens: 12, estimator: wordCount)
        // Every chunk's text should start at a sentence boundary: either the very start of the
        // document, or immediately after a sentence-ending "." + whitespace in the original text.
        for chunk in chunks {
            let isDocumentStart = text.hasPrefix(chunk.text)
            let precededByFullStop = text.range(of: ". " + chunk.text) != nil || text.range(of: ".\n" + chunk.text) != nil
            #expect(isDocumentStart || precededByFullStop)
        }
    }

    // MARK: - Fidelity: no content is lost or duplicated

    @Test func chunksPreserveAllNonWhitespaceContentInOrder() {
        let text = """
        # Title

        \(words(8, prefix: "a"))

        ## Subtitle

        \(words(8, prefix: "b")) Some sentence here. Another one follows.
        """
        let chunks = DocumentChunker.chunk(text, budgetTokens: 6, estimator: wordCount)
        let reconstructed = chunks.map(\.text).joined()
        let strip: (String) -> String = { $0.filter { !$0.isWhitespace } }
        #expect(strip(reconstructed) == strip(text))
    }

    @Test func chunkRangesMatchTheirTextInTheOriginalDocument() {
        let text = "# One\n\n\(words(6))\n\n# Two\n\n\(words(6, prefix: "b"))"
        let chunks = DocumentChunker.chunk(text, budgetTokens: 8, estimator: wordCount)
        let ns = text as NSString
        for chunk in chunks {
            #expect(ns.substring(with: chunk.range.nsRange) == chunk.text)
        }
    }

    // MARK: - Fence awareness

    @Test func blankLinesInsideFencedCodeAreNotParagraphBoundaries() {
        let code = "```\nline one\n\nline two\n```"
        let text = "\(words(6))\n\n\(code)\n\n\(words(6, prefix: "b"))"
        // A generous budget keeps everything as one chunk; the real assertion is that this
        // doesn't crash or misparse the fence — covered implicitly by not throwing. Force a split
        // and check the fence's blank line didn't produce a chunk boundary inside it.
        let chunks = DocumentChunker.chunk(text, budgetTokens: 6, estimator: wordCount)
        for chunk in chunks {
            let opens = chunk.text.components(separatedBy: "```").count - 1
            #expect(opens % 2 == 0) // never an odd number of fence markers in one chunk (no split inside the fence)
        }
    }

    // MARK: - CJK, using the real estimator

    @Test func cjkDocumentSplitsUsingRealEstimator() {
        let paragraph = String(repeating: "你好世界，这是一个测试文档。", count: 20)
        let text = "\(paragraph)\n\n\(paragraph)\n\n\(paragraph)"
        let chunks = DocumentChunker.chunk(text, budgetTokens: 200)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.estimatedTokens <= 200)
        }
        let reconstructed = chunks.map(\.text).joined()
        #expect(reconstructed.filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
    }

    @Test func shortCJKDocumentUnderBudgetIsOneChunk() {
        let text = "你好，世界。这是一个简短的测试。"
        let chunks = DocumentChunker.chunk(text, budgetTokens: TokenEstimator.defaultChunkBudget)
        #expect(chunks.count == 1)
        #expect(chunks[0].text == text)
    }
}
