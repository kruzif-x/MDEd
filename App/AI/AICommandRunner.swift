import Foundation
import MDEdCore

/// A snapshot of an in-flight AI command's progress, for the review UI to show — see
/// `AIReviewView`. `total == 0` means "indeterminate" (the true step count isn't known yet).
struct AIProgress: Equatable {
    var completed: Int
    var total: Int
    var message: String
}

enum AICommandError: Error, LocalizedError {
    case emptyInput
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "There’s nothing here to send to on-device AI."
        case .unavailable(let explanation):
            return explanation
        }
    }
}

/// The result of any AI command run through `AIReview` — the response text, plus (for a command
/// that promises to preserve a source's Markdown markup exactly — Tighten, Translate) a note of
/// any markup the model added beyond what the source had. See `MarkupComparator`'s own doc comment
/// for why this is checked mechanically rather than trusted from the instruction text alone, and
/// `AIReviewView` for where `markupDelta` surfaces to the user before they accept the result.
///
/// `markupDelta` is always `nil` for a command that never promised preservation in the first place
/// (Summarize Document, Summarize Changes) — those have nothing to check, not a clean check.
struct AICommandResult: Equatable {
    let text: String
    let markupDelta: MarkupDelta?
}

/// Orchestrates MDEd's four AI commands on top of a plain `AIService`: chunks oversized input via
/// `MDEdCore.LanguageAwareChunker` / `DiffPromptBuilder`, runs a map (and, for summaries, a reduce)
/// pass chunk by chunk, and reports progress after every chunk.
///
/// Cancellation is checked between chunks, not mid-generation — `LanguageModelSession.respond`
/// isn't interruptible mid-flight, so a `Task.cancel()` takes effect at the next chunk boundary.
/// Given the spike's own latency numbers (well under ten seconds per chunk, most under three), that
/// boundary is frequent enough not to read as unresponsive; see `AIReview` for where the Cancel
/// button drives this.
///
/// Every per-chunk (or per-section) call is wrapped individually: a single chunk the model refuses
/// — a guardrail violation, an oversized chunk that still exceeds the context window on its own —
/// degrades to a noted skip rather than failing the whole command. A document where every chunk
/// fails still surfaces as a real error (there's nothing to show), but one bad chunk out of many no
/// longer costs the user the rest of the result.
struct AICommandRunner {
    let service: AIService

    // MARK: - Summarize document

    private static let summarizeChunkInstructions = """
    You summarize one section of a longer Markdown document. Write a concise, plain-language \
    summary of the key points in this section only. Do not include Markdown formatting, headings, \
    or bullet points in your response — plain prose only.
    """

    private static let summarizeReduceInstructions = """
    You are given a numbered list of section summaries from one document, in the document's own \
    order. Write one coherent, concise summary of the whole document from them. Do not include \
    Markdown formatting in your response — plain prose only.
    """

    private static let summarizeWholeInstructions = """
    Summarize this Markdown document concisely, in plain language. Do not include Markdown \
    formatting in your response — plain prose only.
    """

    /// Summarizes `text`. A document with headings takes the **per-section** path — see
    /// `SummaryPlanner` for why that sidesteps the "summarize the summaries" degradation entirely
    /// for any document structured enough to lean on. A headingless document falls back to the
    /// original map-reduce path, with its reduce step now guided generation (see
    /// `reduceSummariesGuided`) rather than free prose, since that's exactly the headingless case
    /// where a reduce is unavoidable.
    func summarizeDocument(_ text: String, progress: @escaping (AIProgress) -> Void = { _ in }) async throws -> String {
        try requireAvailable()

        if let sections = SummaryPlanner.sectionPlan(for: text, chunker: languageAwareChunker) {
            return try await summarizeBySections(sections, progress: progress)
        }

        let chunks = LanguageAwareChunker.chunk(text, budgetTokens: TokenEstimator.defaultChunkBudget)
        guard !chunks.isEmpty else { throw AICommandError.emptyInput }

        if chunks.count == 1 {
            progress(AIProgress(completed: 0, total: 1, message: "Summarizing…"))
            let result = try await service.generate(instructions: Self.summarizeWholeInstructions, prompt: chunks[0].text)
            progress(AIProgress(completed: 1, total: 1, message: "Done"))
            return result
        }

        var summaries: [String] = []
        var skippedCount = 0
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(AIProgress(completed: index, total: chunks.count + 1, message: "Summarizing part \(index + 1) of \(chunks.count)…"))
            do {
                summaries.append(try await service.generate(instructions: Self.summarizeChunkInstructions, prompt: chunk.text))
            } catch {
                skippedCount += 1
            }
        }
        guard !summaries.isEmpty else {
            throw AICommandError.unavailable("On-device AI declined to process every part of this document.")
        }
        try Task.checkCancellation()
        progress(AIProgress(completed: chunks.count, total: chunks.count + 1, message: "Combining part summaries…"))
        let combined = try await reduceSummariesGuided(summaries, depth: 0)
        progress(AIProgress(completed: chunks.count + 1, total: chunks.count + 1, message: "Done"))
        return combined + skippedNote(skippedCount, of: chunks.count, unit: "part")
    }

    /// The per-section path: one summarize call per section (never a summary of summaries — see
    /// `SummaryPlanner`'s doc comment), assembled into a Markdown outline. A section with more than
    /// one chunk (only an unusually long single section) still gets its own small reduce pass,
    /// scoped to that section alone rather than the whole document.
    private func summarizeBySections(
        _ sections: [DocumentSection], progress: @escaping (AIProgress) -> Void
    ) async throws -> String {
        let totalChunks = max(sections.reduce(0) { $0 + $1.chunks.count }, 1)
        var completed = 0
        var outlineParts: [String] = []
        var skippedTitles: [String] = []

        for section in sections {
            try Task.checkCancellation()
            let label = section.title ?? "Introduction"
            var chunkSummaries: [String] = []
            for chunk in section.chunks {
                try Task.checkCancellation()
                progress(AIProgress(completed: completed, total: totalChunks, message: "Summarizing \(label)…"))
                do {
                    chunkSummaries.append(try await service.generate(instructions: Self.summarizeChunkInstructions, prompt: chunk.text))
                } catch {
                    // One skipped chunk; the rest of this section (and every other section) still
                    // gets a chance.
                }
                completed += 1
            }

            guard !chunkSummaries.isEmpty else {
                skippedTitles.append(label)
                continue
            }
            let sectionSummary: String
            if chunkSummaries.count == 1 {
                sectionSummary = chunkSummaries[0]
            } else {
                sectionSummary = try await reduceSummariesGuided(chunkSummaries, depth: 0)
            }

            if let title = section.title {
                outlineParts.append("## \(title)\n\n\(sectionSummary)")
            } else {
                outlineParts.append(sectionSummary)
            }
        }

        progress(AIProgress(completed: totalChunks, total: totalChunks, message: "Done"))
        guard !outlineParts.isEmpty else {
            throw AICommandError.unavailable("On-device AI declined to summarize every section of this document.")
        }
        return outlineParts.joined(separator: "\n\n") + skippedNote(skippedTitles.count, of: sections.count, unit: "section", titles: skippedTitles)
    }

    /// Combines a numbered list of section/part summaries into one, via **guided generation** (see
    /// `AIService.generateGuidedSummary`) rather than free prose — this is the reduce pass that
    /// asks the model to summarize text that's already a summary, exactly the case observed to
    /// drift toward generic, repetitive phrasing when left to a plain prompt. If the combined list
    /// is itself still over budget — only realistic for a genuinely huge headingless document —
    /// it's chunked and reduced again, recursively, capped at a shallow depth: past that, this
    /// stops trying to compress further and just returns the numbered list as-is rather than
    /// looping. Even in that pathological case the command still produces *something* readable,
    /// never an error.
    private func reduceSummariesGuided(_ summaries: [String], depth: Int) async throws -> String {
        let numbered = summaries.enumerated()
            .map { "Section \($0.offset + 1): \($0.element)" }
            .joined(separator: "\n\n")

        guard TokenEstimator.estimate(numbered) > TokenEstimator.defaultChunkBudget else {
            return try await service.generateGuidedSummary(instructions: Self.summarizeReduceInstructions, prompt: numbered)
        }
        guard depth < 3 else {
            return numbered
        }

        let subChunks = LanguageAwareChunker.chunk(numbered, budgetTokens: TokenEstimator.defaultChunkBudget).map(\.text)
        var subSummaries: [String] = []
        for subChunk in subChunks {
            try Task.checkCancellation()
            do {
                subSummaries.append(try await service.generate(instructions: Self.summarizeChunkInstructions, prompt: subChunk))
            } catch {
                // Skipped; whatever sub-summaries did succeed still get combined below.
            }
        }
        guard !subSummaries.isEmpty else { return numbered }
        return try await reduceSummariesGuided(subSummaries, depth: depth + 1)
    }

    // MARK: - Summarize what changed

    private static let summarizeChangesInstructions = """
    You are given a unified-diff-style rendering of the changes between two versions of a \
    Markdown document: "@@ ... @@" headers mark each changed region, "-" lines were removed, "+" \
    lines were added. Summarize what changed in plain language, as if explaining the edits to the \
    document's author. Do not restate unchanged content or repeat the diff itself — describe the \
    substance of the edits. Do not include Markdown formatting in your response — plain prose only.
    """

    /// Summarizes a diff from its **hunks**, not from the two full documents — see
    /// `DiffPromptBuilder`'s own doc comment for why that's the whole point of this command. Chunks
    /// (rare — only for a very large diff) reduce the same way `summarizeDocument` does.
    func summarizeChanges(
        hunks: [Hunk], left: DocumentLines, right: DocumentLines, progress: @escaping (AIProgress) -> Void = { _ in }
    ) async throws -> String {
        try requireAvailable()
        guard !hunks.isEmpty else { throw AICommandError.emptyInput }
        let chunks = DiffPromptBuilder.chunk(hunks, left: left, right: right, budgetTokens: TokenEstimator.defaultChunkBudget)
        guard !chunks.isEmpty else { throw AICommandError.emptyInput }

        if chunks.count == 1 {
            progress(AIProgress(completed: 0, total: 1, message: "Summarizing changes…"))
            let result = try await service.generate(instructions: Self.summarizeChangesInstructions, prompt: chunks[0])
            progress(AIProgress(completed: 1, total: 1, message: "Done"))
            return result
        }

        var partials: [String] = []
        var skippedCount = 0
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(AIProgress(completed: index, total: chunks.count + 1, message: "Summarizing changes \(index + 1) of \(chunks.count)…"))
            do {
                partials.append(try await service.generate(instructions: Self.summarizeChangesInstructions, prompt: chunk))
            } catch {
                skippedCount += 1
            }
        }
        guard !partials.isEmpty else {
            throw AICommandError.unavailable("On-device AI declined to process every part of this change set.")
        }
        try Task.checkCancellation()
        progress(AIProgress(completed: chunks.count, total: chunks.count + 1, message: "Combining…"))
        let combined = try await reduceSummariesGuided(partials, depth: 0)
        progress(AIProgress(completed: chunks.count + 1, total: chunks.count + 1, message: "Done"))
        return combined + skippedNote(skippedCount, of: chunks.count, unit: "part")
    }

    // MARK: - Tighten selection

    private static let tightenInstructions = """
    Rewrite the following Markdown for concision. Preserve its meaning, its exact Markdown syntax \
    (headings, emphasis, links, code spans, code blocks, lists, tables), and its structure. Return \
    only the rewritten Markdown, nothing else — no preamble, no explanation.
    """

    /// No chunking: a selection large enough to need it is unusual, and Writing Tools already
    /// covers rewriting an ordinary selection — this command exists for the cases that need
    /// Markdown-syntax preservation Writing Tools doesn't promise. A selection that's still too
    /// large surfaces `AIServiceError`'s `exceededContextWindowSize` message rather than silently
    /// failing.
    ///
    /// Verified against `MarkupComparator` — this command has been observed adding `**bold**`
    /// around plain words despite the explicit instruction not to (see this project's README). One
    /// violation gets one retry with a corrective instruction appended; if the model reoffends even
    /// then, the result is still returned (never silently discarded) with `markupDelta` set so
    /// `AIReviewView` can show the user exactly what changed before they accept it.
    func tighten(_ selection: String) async throws -> AICommandResult {
        try requireAvailable()
        guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AICommandError.emptyInput }
        let (text, delta) = try await generatePreservingMarkup(instructions: Self.tightenInstructions, source: selection)
        return AICommandResult(text: text, markupDelta: delta)
    }

    // MARK: - Translate

    private func translateInstructions(to language: String) -> String {
        """
        Translate the following Markdown into \(language). Preserve all Markdown syntax exactly — \
        headings, emphasis, links, code spans, code block contents, list markers, tables, HTML \
        blocks — translating only the prose content, never code. Return only the translated \
        Markdown, nothing else.
        """
    }

    /// Chunks `text` (language-aware — see `LanguageAwareChunker`, which is exactly what makes a
    /// mixed-language document translatable at all instead of risking
    /// `GenerationError.unsupportedLanguageOrLocale` on a chunk that straddled two languages),
    /// translates each chunk, and joins the results back together in order. Unlike
    /// `summarizeDocument`, this is a **map only** — no reduce step — because translation must
    /// preserve every chunk's full content; summarizing it would defeat the point.
    ///
    /// Each chunk is verified against `MarkupComparator` and retried once on a violation, the same
    /// as `tighten(_:)`; a chunk the model refuses outright degrades to a noted skip rather than
    /// failing the whole translation. `markupDelta` on the combined result is the union of every
    /// chunk's own delta (kinds only — see `MarkupDelta`).
    func translate(_ text: String, to language: String, progress: @escaping (AIProgress) -> Void = { _ in }) async throws -> AICommandResult {
        try requireAvailable()
        let chunks = LanguageAwareChunker.chunk(text, budgetTokens: TokenEstimator.defaultChunkBudget)
        guard !chunks.isEmpty else { throw AICommandError.emptyInput }
        let instructions = translateInstructions(to: language)

        var translated: [String] = []
        var introducedKinds: [SyntaxKind] = []

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(AIProgress(completed: index, total: chunks.count, message: "Translating part \(index + 1) of \(chunks.count)…"))
            do {
                let (chunkText, delta) = try await generatePreservingMarkup(instructions: instructions, source: chunk.text)
                translated.append(chunkText)
                if let delta {
                    for kind in delta.introduced where !introducedKinds.contains(kind) {
                        introducedKinds.append(kind)
                    }
                }
            } catch {
                translated.append("_[Part \(index + 1) of \(chunks.count) skipped — on-device AI declined to translate it.]_")
            }
        }
        progress(AIProgress(completed: chunks.count, total: chunks.count, message: "Done"))
        // Skipped parts are already noted inline (above) rather than as a single trailing note,
        // since a skipped part's own position in the document matters for a translation.
        let combined = translated.joined(separator: "\n\n")
        return AICommandResult(text: combined, markupDelta: introducedKinds.isEmpty ? nil : MarkupDelta(introduced: introducedKinds))
    }

    // MARK: - Markup preservation (Tighten, Translate)

    /// Runs `instructions` against `source`, checks the result with `MarkupComparator`, and — only
    /// on a violation — retries once with a corrective instruction appended naming exactly which
    /// markup kinds were added. Returns the retry's result even if it still has a delta: this never
    /// blocks a result from reaching the user, it only makes sure they see what changed (see
    /// `AICommandResult`'s doc comment).
    private func generatePreservingMarkup(instructions: String, source: String) async throws -> (text: String, delta: MarkupDelta?) {
        let first = try await service.generate(instructions: instructions, prompt: source)
        let delta = MarkupComparator.delta(source: source, result: first)
        guard delta.hasChanges else { return (first, nil) }

        let correctiveInstructions = instructions + """


        Your previous attempt introduced Markdown formatting that was not present in the source: \
        \(MarkupKindDescription.describe(delta.introduced)). Do not add any Markdown formatting \
        the source didn't already have — preserve its markup exactly, character for character, \
        adding none.
        """
        let retry = try await service.generate(instructions: correctiveInstructions, prompt: source)
        let retryDelta = MarkupComparator.delta(source: source, result: retry)
        return (retry, retryDelta.hasChanges ? retryDelta : nil)
    }

    // MARK: - Shared

    private func requireAvailable() throws {
        switch service.availability {
        case .available:
            return
        case .unavailable(let explanation):
            throw AICommandError.unavailable(explanation)
        }
    }

    /// `SummaryPlanner`'s `chunker` parameter shape — see its doc comment for why
    /// `LanguageAwareChunker.chunk` is passed here instead of the plain `DocumentChunker` default.
    private func languageAwareChunker(_ text: String, _ budget: Int, _ estimator: @escaping (String) -> Int) -> [DocumentChunk] {
        LanguageAwareChunker.chunk(text, budgetTokens: budget, estimator: estimator)
    }

    /// A trailing note for a result that skipped one or more chunks/sections along the way — never
    /// silent, so the user knows the result is incomplete rather than assuming it's the whole
    /// document. Empty string when nothing was skipped.
    private func skippedNote(_ skipped: Int, of total: Int, unit: String, titles: [String] = []) -> String {
        guard skipped > 0 else { return "" }
        let plural = skipped == 1 ? unit : "\(unit)s"
        if !titles.isEmpty {
            return "\n\n_[Skipped: \(titles.joined(separator: ", ")) — on-device AI declined to process \(skipped == 1 ? "it" : "them").]_"
        }
        return "\n\n_[\(skipped) of \(total) \(plural) skipped — on-device AI declined to process \(skipped == 1 ? "it" : "them").]_"
    }
}
