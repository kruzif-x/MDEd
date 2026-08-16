import Foundation

/// One piece of a document produced by `DocumentChunker.chunk(_:budgetTokens:estimator:)`: the
/// exact source substring it covers, that substring's range in the original document, and the
/// estimated token count `TokenEstimator` assigned it.
public struct DocumentChunk: Sendable, Equatable {
    public let text: String
    public let range: TextRange
    public let estimatedTokens: Int

    public init(text: String, range: TextRange, estimatedTokens: Int) {
        self.text = text
        self.range = range
        self.estimatedTokens = estimatedTokens
    }
}

/// Splits a Markdown document into pieces that fit a token budget, at semantic boundaries — never
/// mid-sentence — so each piece can be sent to FoundationModels on its own.
///
/// This is the load-bearing piece of Stage 4: FoundationModels' 4,096-token context window (see
/// `TokenEstimator`) is smaller than most real documents, so anything beyond a short passage has to
/// be chunked before it can be summarized or translated at all.
///
/// Splitting works in three descending levels, trying each only where the level above wasn't
/// enough:
/// 1. **Headings** — an ATX heading line (`#` through `######`) starts a new section; text before
///    the first heading (or a document with none) is its own section.
/// 2. **Paragraphs** — a blank-line run (outside a fenced code block — see `FencedCodeTracker`)
///    separates paragraphs, for any section still over budget on its own.
/// 3. **Sentences** — `.`/`!`/`?` (and the CJK equivalents `。`/`！`/`？`) followed by whitespace,
///    for any paragraph still over budget on its own.
///
/// At every level, adjacent units are packed greedily into as few chunks as possible (so ten short
/// paragraphs that together fit the budget become one chunk, not ten) and only a unit that
/// individually exceeds the budget gets split further. If a single *sentence* still exceeds the
/// budget — one run-on sentence with no internal punctuation, pathologically long — there is
/// nothing left to split without cutting mid-sentence, so it's returned whole, over budget, rather
/// than butchered. That chunk's own `estimatedTokens` will read higher than `budgetTokens`; a
/// caller sending it to FoundationModels should expect (and handle) a possible
/// `GenerationError.exceededContextWindowSize` from that one chunk, same as it would from any
/// single passage too large to summarize at all.
public enum DocumentChunker {

    /// Splits `text` into budget-fitting chunks. Empty or whitespace-only input produces no chunks
    /// at all — there's nothing to summarize or translate, and returning one empty chunk would just
    /// push that judgment call onto every caller instead of making it once, here.
    public static func chunk(
        _ text: String,
        budgetTokens: Int = TokenEstimator.defaultChunkBudget,
        estimator: (String) -> Int = TokenEstimator.estimate
    ) -> [DocumentChunk] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        if estimator(text) <= budgetTokens {
            return [makeChunk(fullText: text, range: text.startIndex..<text.endIndex, estimator: estimator)]
        }

        let sections = headingUnits(in: Substring(text))
        if sections.count > 1 {
            return pack(sections, fullText: text, budget: budgetTokens, estimator: estimator) { unitText, unitRange in
                chunkByParagraphs(unitText, range: unitRange, fullText: text, budget: budgetTokens, estimator: estimator)
            }
        }
        return chunkByParagraphs(Substring(text), range: text.startIndex..<text.endIndex, fullText: text, budget: budgetTokens, estimator: estimator)
    }

    // MARK: - Level 2: paragraphs

    private static func chunkByParagraphs(
        _ sectionText: Substring, range: Range<String.Index>, fullText: String, budget: Int, estimator: (String) -> Int
    ) -> [DocumentChunk] {
        let paragraphs = paragraphUnits(in: sectionText)
        guard paragraphs.count > 1 else {
            return chunkBySentences(sectionText, range: range, fullText: fullText, budget: budget, estimator: estimator)
        }
        return pack(paragraphs, fullText: fullText, budget: budget, estimator: estimator) { unitText, unitRange in
            chunkBySentences(unitText, range: unitRange, fullText: fullText, budget: budget, estimator: estimator)
        }
    }

    // MARK: - Level 3: sentences (the base case)

    private static func chunkBySentences(
        _ paragraphText: Substring, range: Range<String.Index>, fullText: String, budget: Int, estimator: (String) -> Int
    ) -> [DocumentChunk] {
        let sentences = sentenceUnits(in: paragraphText)
        guard sentences.count > 1 else {
            // Nothing left to split on — either one sentence, or no sentence-ending punctuation at
            // all. Returned whole even if still over budget; see this type's doc comment.
            return [makeChunk(fullText: fullText, range: range, estimator: estimator)]
        }
        return pack(sentences, fullText: fullText, budget: budget, estimator: estimator) { unitText, unitRange in
            // A single sentence that alone exceeds the budget is the true base case: there is
            // nothing left to split without cutting mid-sentence.
            [makeChunk(fullText: fullText, range: unitRange, estimator: estimator)]
        }
    }

    // MARK: - Greedy packing

    /// Combines consecutive `units` into as few chunks as possible, each staying under `budget`.
    /// A unit that alone exceeds `budget` is handed to `splitOversized` instead of being force-fit;
    /// whatever chunks that produces are inserted in place, and packing resumes after it.
    private static func pack(
        _ units: [(text: Substring, range: Range<String.Index>)],
        fullText: String,
        budget: Int,
        estimator: (String) -> Int,
        splitOversized: (Substring, Range<String.Index>) -> [DocumentChunk]
    ) -> [DocumentChunk] {
        var chunks: [DocumentChunk] = []
        var groupRange: Range<String.Index>?

        func flush() {
            guard let groupRange else { return }
            chunks.append(makeChunk(fullText: fullText, range: groupRange, estimator: estimator))
        }

        for unit in units {
            guard !unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let unitEstimate = estimator(String(unit.text))
            if unitEstimate > budget {
                flush()
                groupRange = nil
                chunks.append(contentsOf: splitOversized(unit.text, unit.range))
                continue
            }

            if let existing = groupRange {
                let candidate = existing.lowerBound..<unit.range.upperBound
                if estimator(String(fullText[candidate])) <= budget {
                    groupRange = candidate
                    continue
                }
                flush()
            }
            groupRange = unit.range
        }
        flush()
        return chunks
    }

    private static func makeChunk(fullText: String, range: Range<String.Index>, estimator: (String) -> Int) -> DocumentChunk {
        let text = String(fullText[range])
        let nsRange = NSRange(range, in: fullText)
        return DocumentChunk(
            text: text,
            range: TextRange(lowerBound: nsRange.location, upperBound: nsRange.location + nsRange.length),
            estimatedTokens: estimator(text)
        )
    }

    // MARK: - Boundary detection

    /// Built fresh per call rather than cached as a `static let` — a compiled `Regex` isn't
    /// `Sendable`, and this codebase's existing regex helpers (see `WordCount.swift`) take the
    /// same approach for the same reason. Recompiling a short pattern is not a meaningful cost next
    /// to the parse/estimate work already happening around every call site.
    private static func headingLineRegex() -> Regex<AnyRegexOutput> { try! Regex(#"^#{1,6}(\s|$)"#) }

    /// A best-effort sentence boundary, not a real NLP sentence tokenizer (an abbreviation like
    /// "e.g." splits same as a real sentence end would). Two alternatives, because ASCII and CJK
    /// prose punctuate sentence ends differently: `.`/`!`/`?` require *trailing whitespace* to
    /// count (so "e.g." mid-sentence doesn't `Regex`-match on its own merits any more than it
    /// otherwise would, and a decimal like "3.14" is never mistaken for a boundary since nothing
    /// follows the `.` there); `。`/`！`/`？` split on their own, with no whitespace requirement,
    /// since CJK prose conventionally has none between sentences. Good enough for "don't cut
    /// mid-sentence" on ordinary prose in either script; not attempted on non-prose content
    /// differently — see this type's doc comment for the code-block base-case tradeoff that
    /// follows from that.
    private static func sentenceTerminatorRegex() -> Regex<AnyRegexOutput> { try! Regex(#"[.!?]+\s+|[。！？]+\s*"#) }

    /// Splits `text` at every ATX heading line (fence-aware — a `#`-looking line inside a fenced
    /// code block doesn't count), gaplessly partitioning the whole input.
    private static func headingUnits(in text: Substring) -> [(text: Substring, range: Range<String.Index>)] {
        let (ranges, insideFence) = lines(in: text)
        let regex = headingLineRegex()
        var splitPoints: [String.Index] = []
        for (index, lineRange) in ranges.enumerated() where !insideFence[index] {
            if text[lineRange].firstMatch(of: regex) != nil {
                splitPoints.append(lineRange.lowerBound)
            }
        }
        return partition(text, at: splitPoints)
    }

    /// Splits `text` at every paragraph boundary — the first non-blank line following one or more
    /// blank lines (fence-aware: a blank line inside a fenced code block doesn't separate
    /// paragraphs, and isn't itself treated as a paragraph start either).
    private static func paragraphUnits(in text: Substring) -> [(text: Substring, range: Range<String.Index>)] {
        let (ranges, insideFence) = lines(in: text)
        func isBlank(_ index: Int) -> Bool {
            !insideFence[index] && String(text[ranges[index]]).trimmingCharacters(in: .whitespaces).isEmpty
        }
        var splitPoints: [String.Index] = []
        guard ranges.count > 1 else { return partition(text, at: []) }
        for index in 1..<ranges.count where !isBlank(index) && isBlank(index - 1) {
            splitPoints.append(ranges[index].lowerBound)
        }
        return partition(text, at: splitPoints)
    }

    /// Splits `text` at every detected sentence boundary (see `sentenceTerminatorRegex`).
    private static func sentenceUnits(in text: Substring) -> [(text: Substring, range: Range<String.Index>)] {
        var splitPoints: [String.Index] = []
        for match in text.matches(of: sentenceTerminatorRegex()) {
            let end = match.range.upperBound
            if end < text.endIndex { splitPoints.append(end) }
        }
        return partition(text, at: splitPoints)
    }

    /// Line ranges (excluding the trailing `"\n"`) within `text`, alongside whether each is inside
    /// a fenced code block — the shared scan every boundary detector above builds on.
    private static func lines(in text: Substring) -> (ranges: [Range<String.Index>], insideFence: [Bool]) {
        var ranges: [Range<String.Index>] = []
        var lineStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\n" {
                ranges.append(lineStart..<index)
                index = text.index(after: index)
                lineStart = index
            } else {
                index = text.index(after: index)
            }
        }
        ranges.append(lineStart..<text.endIndex)
        let insideFence = FencedCodeTracker.linesInsideFence(ranges.map { String(text[$0]) })
        return (ranges, insideFence)
    }

    /// Gaplessly partitions `text` at `splitPoints` (each the start of a new unit), dropping any
    /// point outside `text`'s own bounds and any resulting empty span.
    private static func partition(_ text: Substring, at splitPoints: [String.Index]) -> [(text: Substring, range: Range<String.Index>)] {
        var points = Set(splitPoints.filter { $0 > text.startIndex && $0 < text.endIndex })
        points.insert(text.startIndex)
        points.insert(text.endIndex)
        let sorted = points.sorted()

        var result: [(Substring, Range<String.Index>)] = []
        for index in 0..<(sorted.count - 1) {
            let range = sorted[index]..<sorted[index + 1]
            guard !range.isEmpty else { continue }
            result.append((text[range], range))
        }
        return result
    }
}
