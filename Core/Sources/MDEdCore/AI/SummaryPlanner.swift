import Foundation

/// One top-level section of a document, planned for `AICommandRunner.summarizeDocument`'s
/// per-section path — see `SummaryPlanner.sectionPlan(for:)`.
public struct DocumentSection: Sendable, Equatable {
    /// The section's heading text, Markdown stripped (via `TableOfContents`) — `nil` for the
    /// preamble section (any text before the document's first top-level heading), if there is one.
    public let title: String?

    /// `1` for every heading-derived section, `0` only for the untitled preamble section — a
    /// normalized flag, not the raw ATX heading depth (`#` vs `##`): see `SummaryPlanner.sectionPlan`
    /// for why only one depth is ever actually used to split a given document, so there is nothing
    /// deeper than "1" to distinguish.
    public let level: Int

    /// The section's own text (heading line included, up to but not including the next top-level
    /// heading), already split into budget-fitting pieces by `DocumentChunker` — almost always one
    /// piece; more than one only for a single section long enough on its own to need it.
    public let chunks: [DocumentChunk]

    public init(title: String?, level: Int, chunks: [DocumentChunk]) {
        self.title = title
        self.level = level
        self.chunks = chunks
    }
}

/// Plans the per-section summary path `AICommandRunner.summarizeDocument` uses for any document
/// that has headings, in place of the "summarize the summaries" reduce pass every other chunked
/// AI command in this app uses.
///
/// That reduce pass is what degrades on a large document: it asks the model to summarize text
/// that's already a summary, and the result drifts toward generic, repetitive phrasing ("designed
/// to be user-friendly… designed to be accessible…") rather than compressing further. A document
/// with headings already carries a structure that sidesteps the problem instead of trying to
/// paper over it: summarize each top-level section once, on its own, and present the result as an
/// outline — no second pass over already-summarized text at all. See `AICommandRunner`'s use of
/// this type for how those per-section summaries turn into the outline itself; this type only
/// plans *what* to summarize, not the summarizing.
public enum SummaryPlanner {

    /// Splits `text` at its **split level** — the shallowest heading level that has more than one
    /// heading at it, falling back to the shallowest level present at all if no level repeats (e.g.
    /// a document with exactly one heading, or one `#` above a single `##`, has nothing to split on
    /// yet still gets that one heading as its own section). One `DocumentSection` per heading at
    /// that level, each pre-chunked to fit `budgetTokens`, in document order.
    ///
    /// A solitary heading shallower than the split level (the common case: a lone `#` document
    /// title sitting above several `##` sections) is not itself a split point — it reads as the
    /// document's title, not a section boundary — but it isn't discarded either: the leading span it
    /// introduces becomes its own titled section, using that heading's own text, rather than an
    /// untitled preamble. Only genuinely heading-free leading text (no heading at all before the
    /// first split-level one) becomes an untitled, `level: 0` preamble section.
    ///
    /// `level` on every heading-derived section (including that title-as-section case) is
    /// normalized to `1` — it flags "this section came from a heading" rather than echoing the raw
    /// ATX depth, since only one depth is ever actually used to split a given document. `0` marks
    /// the untitled-preamble case only.
    ///
    /// Returns `nil` when `text` has no headings at all — headingless documents have no structure
    /// for this path to lean on, so the caller falls back to a plain map/reduce instead (guided
    /// generation for the reduce step; see `AICommandRunner`).
    /// - Parameter chunker: How each section's own text is split into budget-fitting
    ///   `DocumentChunk`s — defaults to plain `DocumentChunker.chunk`. `AICommandRunner` passes
    ///   `LanguageAwareChunker.chunk` instead so a section that itself mixes languages (rare, but
    ///   possible for a long section) still gets language-aware chunk boundaries, the same
    ///   protection every other chunked AI command in this app gets.
    public static func sectionPlan(
        for text: String,
        budgetTokens: Int = TokenEstimator.defaultChunkBudget,
        estimator: @escaping (String) -> Int = TokenEstimator.estimate,
        chunker: (String, Int, @escaping (String) -> Int) -> [DocumentChunk] = { text, budget, estimator in
            DocumentChunker.chunk(text, budgetTokens: budget, estimator: estimator)
        }
    ) -> [DocumentSection]? {
        let entries = TableOfContents.entries(from: text)
        guard !entries.isEmpty else { return nil }

        guard let splitLevel = splitLevel(for: entries) else { return nil }
        let splitEntries = entries.filter { $0.level == splitLevel }
        guard !splitEntries.isEmpty else { return nil }

        let ns = text as NSString
        var sections: [DocumentSection] = []

        if let first = splitEntries.first, first.range.lowerBound > 0 {
            let preambleRange = NSRange(location: 0, length: min(first.range.lowerBound, ns.length))
            let preamble = ns.substring(with: preambleRange)
            if !preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A shallower heading (the document's own title) sitting ahead of the first
                // split-level heading names this section instead of leaving it untitled.
                let leadingHeading = entries.first.flatMap { entry -> TOCEntry? in
                    entry.level < splitLevel && entry.range.lowerBound < first.range.lowerBound ? entry : nil
                }
                sections.append(DocumentSection(
                    title: leadingHeading.flatMap { $0.title.isEmpty ? nil : $0.title },
                    level: leadingHeading == nil ? 0 : 1,
                    chunks: chunker(preamble, budgetTokens, estimator)
                ))
            }
        }

        for (index, entry) in splitEntries.enumerated() {
            let start = entry.range.lowerBound
            let end = index + 1 < splitEntries.count ? splitEntries[index + 1].range.lowerBound : ns.length
            guard start >= 0, end > start, end <= ns.length else { continue }
            let sectionText = ns.substring(with: NSRange(location: start, length: end - start))
            sections.append(DocumentSection(
                title: entry.title.isEmpty ? nil : entry.title,
                level: 1,
                chunks: chunker(sectionText, budgetTokens, estimator)
            ))
        }

        return sections.isEmpty ? nil : sections
    }

    /// The shallowest heading level with more than one heading at it, or — when no level repeats —
    /// the shallowest level present at all. `nil` only when `entries` is empty (callers already
    /// guard that case, but this stays total rather than assuming).
    private static func splitLevel(for entries: [TOCEntry]) -> Int? {
        let levels = Set(entries.map(\.level)).sorted()
        for level in levels {
            let count = entries.reduce(into: 0) { count, entry in
                if entry.level == level { count += 1 }
            }
            if count > 1 { return level }
        }
        return levels.first
    }
}
