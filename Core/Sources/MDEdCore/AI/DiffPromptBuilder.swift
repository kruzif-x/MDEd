/// Turns a diff's `hunks(in:)` result into text suitable for asking FoundationModels "what
/// changed?" — the input for Stage 4's "Summarize What Changed" command.
///
/// The critical design point, called out in this project's own planning notes: this renders the
/// **hunks**, not the two full documents. Two full documents blow the 4,096-token context window
/// (`TokenEstimator.contextWindowLimit`) almost immediately for anything beyond a short file; a
/// hunk list's size tracks how much actually *changed*, not how long either document is, so a
/// three-line edit to a 10,000-word document renders (and fits the budget) in a few dozen tokens
/// regardless of the document's own size. `DiffPromptBuilderTests` pins exactly this: a huge
/// shared document with a tiny diff stays a single small chunk, where feeding both full documents
/// never would.
public enum DiffPromptBuilder {

    /// Renders `hunks` as a compact, unified-diff-flavored text block: one `@@ ... @@` header per
    /// hunk (1-based line numbers, matching how a human reads a diff) followed by its `-`/`+`
    /// lines, hunks separated by a single blank line.
    ///
    /// The blank-line separation is deliberate, not cosmetic: `chunk(_:left:right:budgetTokens:estimator:)`
    /// below hands this straight to `DocumentChunker`, whose paragraph-level splitting treats a
    /// blank-line run as a unit boundary — so each hunk becomes exactly one packable unit, with no
    /// separate hunk-aware chunking logic needed. A hunk's own lines are kept contiguous (no blank
    /// line introduced *within* one), so this alignment is exact.
    public static func renderHunks(_ hunks: [Hunk], left: DocumentLines, right: DocumentLines) -> String {
        hunks.map { block(for: $0, left: left, right: right) }.joined(separator: "\n\n")
    }

    /// Renders `hunks` and splits the result into chunks that fit `budgetTokens`, reusing
    /// `DocumentChunker`'s heading/paragraph/sentence cascade (see `renderHunks(_:left:right:)`
    /// for why paragraph-level splitting alone already aligns to hunk boundaries). Returns plain
    /// text — unlike `DocumentChunker.chunk`, a diff summary is never mapped back to a source
    /// range, so there's no reason to carry one.
    public static func chunk(
        _ hunks: [Hunk],
        left: DocumentLines,
        right: DocumentLines,
        budgetTokens: Int = TokenEstimator.defaultChunkBudget,
        estimator: (String) -> Int = TokenEstimator.estimate
    ) -> [String] {
        guard !hunks.isEmpty else { return [] }
        let rendered = renderHunks(hunks, left: left, right: right)
        return DocumentChunker.chunk(rendered, budgetTokens: budgetTokens, estimator: estimator).map(\.text)
    }

    // MARK: - Rendering

    private static func block(for hunk: Hunk, left: DocumentLines, right: DocumentLines) -> String {
        var lines: [String] = [header(for: hunk)]
        for entry in hunk.entries {
            switch entry.kind {
            case .removed:
                if let index = entry.leftIndex { lines.append("- " + left.lines[index]) }
            case .inserted:
                if let index = entry.rightIndex { lines.append("+ " + right.lines[index]) }
            case .changed:
                if let index = entry.leftIndex { lines.append("- " + left.lines[index]) }
                if let index = entry.rightIndex { lines.append("+ " + right.lines[index]) }
            case .unchanged:
                // A hunk (see `hunks(in:)`) never contains an `.unchanged` entry — defensive only.
                continue
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func header(for hunk: Hunk) -> String {
        var parts: [String] = []
        if let leftRange = hunk.leftRange {
            parts.append("left \(leftRange.lowerBound + 1)-\(leftRange.upperBound)")
        }
        if let rightRange = hunk.rightRange {
            parts.append("right \(rightRange.lowerBound + 1)-\(rightRange.upperBound)")
        }
        return "@@ " + parts.joined(separator: ", ") + " @@"
    }
}
