import Foundation
import NaturalLanguage

/// Splits a document into `DocumentChunker`-budgeted chunks the same way `DocumentChunker.chunk`
/// does, but first partitions it at detected language-boundary points, so a single chunk this
/// produces never mixes two languages the way a purely budget-driven pack sometimes did — a chunk
/// straddling, say, an English section and a Portuguese one, which FoundationModels can reject
/// outright with `GenerationError.unsupportedLanguageOrLocale`.
///
/// ## Why per-block detection, not per-line or whole-document
///
/// A naive "detect the language of every line/paragraph and split wherever it changes" breaks on
/// ordinary Markdown: run `NLLanguageRecognizer` on a heading like `"## Installation"` alone and it
/// can come back confidently — and wrongly — as French; a fenced code block, a table row, or a
/// bare URL are similarly unreliable, since none of them carry the prose signal the recognizer
/// needs. Splitting on every such false read would force a bogus chunk boundary at every heading
/// and mis-tag the section behind it.
///
/// So this only ever runs the recognizer on **prose blocks** — the text `syntaxMap(of:)` does
/// *not* attribute to a heading, code block, diagram block, or table (see `isProse(_:)`) — and
/// only trusts the result above a confidence floor and a minimum length (`minConfidence`,
/// `minLength`); anything else is "unclassified" and **inherits the previous prose block's
/// language** rather than forcing a split. A heading between two English paragraphs never starts a
/// new segment, no matter what the recognizer would say about the heading text on its own, because
/// the heading is never handed to it in the first place.
///
/// ## Known, accepted residual limit
///
/// A single paragraph that itself mixes two languages (`"Install with Homebrew. 使用 Homebrew
/// 安装本工具。"`) reports whichever language dominates that one block, with no signal that it was
/// mixed — one paragraph is too small to trigger the chunk-scale failure this exists to prevent,
/// and there's no reliable way to split *within* a paragraph without risking the same
/// heading-as-French false positive at finer grain. Documented, not chased.
public enum LanguageAwareChunker {

    /// The confidence `NLLanguageRecognizer` must report before a prose block's detected language
    /// is trusted — calibrated against the spike's own numbers: reliable prose scored 0.98–1.00;
    /// the worst structural false positive (a heading read as French) scored 0.49. 0.85 sits well
    /// above every structural false reading observed and well below every genuine prose reading.
    public static let minConfidence = 0.85

    /// The minimum trimmed character length a prose block must have before its detected language
    /// is trusted at all — guards against a short prose-shaped block (a one-line caption, a lone
    /// short sentence) where even a high confidence score is thin evidence.
    public static let minLength = 20

    /// One document segment: a contiguous span of `LanguageAwareChunker`'s own analysis at the same
    /// resolved language. `language` is the BCP-47-ish tag `NLLanguageRecognizer` reported (e.g.
    /// `"en"`, `"pt"`, `"zh-Hans"`), or `nil` if this segment's language was never confidently
    /// classified (e.g. a document, or document prefix, with no prose to detect at all — a table
    /// or code sample before any prose paragraph).
    public struct Segment: Sendable, Equatable {
        public let range: TextRange
        public let text: String
        public let language: String?
    }

    /// Splits `text` into chunks, never packing two different confidently-detected languages into
    /// the same chunk. Falls straight through to plain `DocumentChunker.chunk` behavior for a
    /// document that's entirely one language (or has no classifiable prose at all) — this only
    /// changes behavior at an actual language boundary.
    public static func chunk(
        _ text: String,
        budgetTokens: Int = TokenEstimator.defaultChunkBudget,
        estimator: (String) -> Int = TokenEstimator.estimate,
        languageDetector: (String) -> String? = detectLanguage
    ) -> [DocumentChunk] {
        var chunks: [DocumentChunk] = []
        for segment in segments(of: text, languageDetector: languageDetector) {
            let segmentChunks = DocumentChunker.chunk(segment.text, budgetTokens: budgetTokens, estimator: estimator)
            chunks.append(contentsOf: segmentChunks.map { offset($0, by: segment.range.lowerBound) })
        }
        return chunks
    }

    /// Partitions `text` at detected language-boundary points — exposed (not just used internally
    /// by `chunk`) so tests can pin the boundary-detection logic itself, independent of
    /// `DocumentChunker`'s own budget-packing behavior.
    public static func segments(
        of text: String,
        languageDetector: (String) -> String? = detectLanguage
    ) -> [Segment] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let blocks = proseBlocks(in: text)
        guard !blocks.isEmpty else {
            return [Segment(range: TextRange(lowerBound: 0, upperBound: ns.length), text: text, language: nil)]
        }

        // `boundaries[0]` always starts at 0. Its language is filled in retroactively by the
        // *first* block that ever gets a confident reading, whatever that block's own position —
        // there is no "previous language" yet to contrast it against, so it covers the document
        // from the start rather than forcing a split right before itself (the common case: a
        // document opening with a heading, or any other structural content, ahead of its first
        // paragraph). Every later element marks a genuine detected language *change* — a block
        // whose reading differs from a language already established — at that block's own start.
        var boundaries: [(start: Int, language: String?)] = [(0, nil)]
        var currentLanguage: String?

        for block in blocks {
            guard block.isProse else { continue }
            let blockText = ns.substring(with: NSRange(location: block.range.lowerBound, length: block.range.length))
            guard let detected = languageDetector(blockText) else { continue }
            guard detected != currentLanguage else { continue }

            if currentLanguage == nil {
                boundaries[0].language = detected
            } else {
                boundaries.append((block.range.lowerBound, detected))
            }
            currentLanguage = detected
        }

        var segments: [Segment] = []
        for (index, boundary) in boundaries.enumerated() {
            let end = index + 1 < boundaries.count ? boundaries[index + 1].start : ns.length
            guard end > boundary.start else { continue }
            let segmentText = ns.substring(with: NSRange(location: boundary.start, length: end - boundary.start))
            segments.append(Segment(
                range: TextRange(lowerBound: boundary.start, upperBound: end),
                text: segmentText,
                language: boundary.language
            ))
        }
        return segments
    }

    // MARK: - Language detection

    /// The real detector `chunk`/`segments` use by default: `NLLanguageRecognizer`, on-device,
    /// system-provided (`NaturalLanguage`), no network, no dependency. Returns `nil` (unclassified)
    /// below either `minLength` or `minConfidence`.
    public static func detectLanguage(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minLength else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let confidence = hypotheses[dominant], confidence >= minConfidence else { return nil }
        return dominant.rawValue
    }

    // MARK: - Prose/structural block detection

    private struct Block {
        let range: TextRange
        let isProse: Bool
    }

    /// The syntax kinds treated as "structural" — never handed to the language recognizer, no
    /// matter how the recognizer would read their raw text. Everything else (ordinary paragraphs,
    /// list item text, block quote text) is prose.
    private static func isStructural(_ kind: SyntaxKind) -> Bool {
        switch kind {
        case .heading, .codeBlock, .diagramBlock, .table, .thematicBreak:
            return true
        case .emphasis, .strong, .strikethrough, .inlineCode, .inlineMath, .displayMath, .link, .image, .listItem, .blockQuote:
            return false
        }
    }

    /// A line's role for `proseBlocks(in:)`'s grouping — three-way, not the two-way
    /// prose/structural split the resulting `Block`s expose, so a blank line never gets folded into
    /// an adjacent paragraph's block (see `proseBlocks(in:)`'s doc comment for why that distinction
    /// matters).
    private enum LineRole: Equatable {
        case structural
        case blank
        case prose
    }

    /// Splits `text` into maximal contiguous line-runs of the same prose/structural classification,
    /// using `syntaxMap(of:)`'s own element ranges (see `isStructural(_:)`) so this leans on the
    /// same tested Markdown parse the rest of the app does, rather than re-deriving fence/table/
    /// heading detection from scratch.
    ///
    /// Grouping is **paragraph-grained**: a blank line is its own `LineRole`, distinct from the
    /// prose text around it, so it never merges into one block with a neighboring paragraph the way
    /// a plain "same isProse flag" merge would. That distinction is load-bearing — without it, a
    /// paragraph immediately preceded or followed by a blank line (i.e. almost every paragraph in
    /// ordinary Markdown) produces a block whose *text* starts or ends with blank lines rather than
    /// exactly the paragraph itself, which is fine for the real detector (it trims before use) but
    /// silently defeats any caller — a test rig, or a future detector — that inspects the block's
    /// raw text directly. Consecutive non-blank prose lines (a paragraph soft-wrapped across
    /// several lines with no blank line between) still merge into a single block, same as before.
    private static func proseBlocks(in text: String) -> [Block] {
        guard !text.isEmpty else { return [] }
        let units = Array(text.utf16)
        let structuralRanges = syntaxMap(of: text)
            .filter { isStructural($0.kind) }
            .map(\.range)

        let lineRanges = self.lineRanges(units: units)
        func lineIsStructural(_ range: Range<Int>) -> Bool {
            structuralRanges.contains { $0.lowerBound < range.upperBound && $0.upperBound > range.lowerBound }
        }
        func role(of range: Range<Int>) -> LineRole {
            if lineIsStructural(range) { return .structural }
            let lineText = String(decoding: units[range], as: UTF16.self)
            return lineText.trimmingCharacters(in: .whitespaces).isEmpty ? .blank : .prose
        }

        var blocks: [Block] = []
        var runStart = 0
        var runRole: LineRole?

        for lineRange in lineRanges {
            let lineRole = role(of: lineRange)
            if let current = runRole, current == lineRole {
                continue
            }
            if let current = runRole {
                blocks.append(Block(range: TextRange(lowerBound: runStart, upperBound: lineRange.lowerBound), isProse: current != .structural))
            }
            runStart = lineRange.lowerBound
            runRole = lineRole
        }
        if let last = runRole {
            blocks.append(Block(range: TextRange(lowerBound: runStart, upperBound: units.count), isProse: last != .structural))
        }
        return blocks
    }

    private static func lineRanges(units: [UInt16]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var lineStart = 0
        var index = 0
        let newline: UInt16 = 0x0A
        while index < units.count {
            if units[index] == newline {
                ranges.append(lineStart..<index)
                index += 1
                lineStart = index
            } else {
                index += 1
            }
        }
        ranges.append(lineStart..<units.count)
        return ranges
    }

    // MARK: - Chunk range offsetting

    private static func offset(_ chunk: DocumentChunk, by delta: Int) -> DocumentChunk {
        DocumentChunk(
            text: chunk.text,
            range: TextRange(lowerBound: chunk.range.lowerBound + delta, upperBound: chunk.range.upperBound + delta),
            estimatedTokens: chunk.estimatedTokens
        )
    }
}
