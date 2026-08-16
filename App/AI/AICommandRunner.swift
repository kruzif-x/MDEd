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

/// Orchestrates MDEd's four AI commands on top of a plain `AIService`: chunks oversized input via
/// `MDEdCore.DocumentChunker` / `DiffPromptBuilder`, runs a map (and, for summaries, a reduce) pass
/// chunk by chunk, and reports progress after every chunk.
///
/// Cancellation is checked between chunks, not mid-generation — `LanguageModelSession.respond`
/// isn't interruptible mid-flight, so a `Task.cancel()` takes effect at the next chunk boundary.
/// Given the spike's own latency numbers (well under ten seconds per chunk, most under three), that
/// boundary is frequent enough not to read as unresponsive; see `AIReview` for where the Cancel
/// button drives this.
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

    /// Summarizes `text`. Chunks it first if it's over budget, summarizes each chunk, then
    /// summarizes those summaries into one — "summarize the summaries", the map-reduce this
    /// command is built on. A document that chunks into dozens of pieces (a very long one) reduces
    /// recursively rather than trying to fit every chunk summary into one final call; see
    /// `reduceSummaries`.
    func summarizeDocument(_ text: String, progress: @escaping (AIProgress) -> Void = { _ in }) async throws -> String {
        try requireAvailable()
        let chunks = DocumentChunker.chunk(text, budgetTokens: TokenEstimator.defaultChunkBudget)
        guard !chunks.isEmpty else { throw AICommandError.emptyInput }

        if chunks.count == 1 {
            progress(AIProgress(completed: 0, total: 1, message: "Summarizing…"))
            let result = try await service.generate(instructions: Self.summarizeWholeInstructions, prompt: chunks[0].text)
            progress(AIProgress(completed: 1, total: 1, message: "Done"))
            return result
        }

        var summaries: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(AIProgress(completed: index, total: chunks.count + 1, message: "Summarizing section \(index + 1) of \(chunks.count)…"))
            summaries.append(try await service.generate(instructions: Self.summarizeChunkInstructions, prompt: chunk.text))
        }
        try Task.checkCancellation()
        progress(AIProgress(completed: chunks.count, total: chunks.count + 1, message: "Combining section summaries…"))
        let combined = try await reduceSummaries(summaries, depth: 0)
        progress(AIProgress(completed: chunks.count + 1, total: chunks.count + 1, message: "Done"))
        return combined
    }

    /// Combines a numbered list of section summaries into one. If the combined list is itself still
    /// over budget — only realistic for a genuinely huge document (tens of thousands of words,
    /// chunking into dozens of sections) — it's chunked and reduced again, recursively. Capped at a
    /// shallow depth: past that, this stops trying to compress further and just returns the
    /// numbered list as-is rather than looping. Even in that pathological case the command still
    /// produces *something* readable, never an error — the outcome Stage 4 requires.
    private func reduceSummaries(_ summaries: [String], depth: Int) async throws -> String {
        let numbered = summaries.enumerated()
            .map { "Section \($0.offset + 1): \($0.element)" }
            .joined(separator: "\n\n")

        guard TokenEstimator.estimate(numbered) > TokenEstimator.defaultChunkBudget else {
            return try await service.generate(instructions: Self.summarizeReduceInstructions, prompt: numbered)
        }
        guard depth < 3 else {
            return numbered
        }

        let subChunks = DocumentChunker.chunk(numbered, budgetTokens: TokenEstimator.defaultChunkBudget).map(\.text)
        var subSummaries: [String] = []
        for subChunk in subChunks {
            try Task.checkCancellation()
            subSummaries.append(try await service.generate(instructions: Self.summarizeChunkInstructions, prompt: subChunk))
        }
        return try await reduceSummaries(subSummaries, depth: depth + 1)
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
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(AIProgress(completed: index, total: chunks.count + 1, message: "Summarizing changes \(index + 1) of \(chunks.count)…"))
            partials.append(try await service.generate(instructions: Self.summarizeChangesInstructions, prompt: chunk))
        }
        try Task.checkCancellation()
        progress(AIProgress(completed: chunks.count, total: chunks.count + 1, message: "Combining…"))
        let combined = try await reduceSummaries(partials, depth: 0)
        progress(AIProgress(completed: chunks.count + 1, total: chunks.count + 1, message: "Done"))
        return combined
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
    func tighten(_ selection: String) async throws -> String {
        try requireAvailable()
        guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AICommandError.emptyInput }
        return try await service.generate(instructions: Self.tightenInstructions, prompt: selection)
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

    /// Chunks `text`, translates each chunk, and joins the results back together in order. Unlike
    /// `summarizeDocument`, this is a **map only** — no reduce step — because translation must
    /// preserve every chunk's full content; summarizing it would defeat the point.
    func translate(_ text: String, to language: String, progress: @escaping (AIProgress) -> Void = { _ in }) async throws -> String {
        try requireAvailable()
        let chunks = DocumentChunker.chunk(text, budgetTokens: TokenEstimator.defaultChunkBudget)
        guard !chunks.isEmpty else { throw AICommandError.emptyInput }
        let instructions = translateInstructions(to: language)

        if chunks.count == 1 {
            progress(AIProgress(completed: 0, total: 1, message: "Translating…"))
            let result = try await service.generate(instructions: instructions, prompt: chunks[0].text)
            progress(AIProgress(completed: 1, total: 1, message: "Done"))
            return result
        }

        var translated: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(AIProgress(completed: index, total: chunks.count, message: "Translating part \(index + 1) of \(chunks.count)…"))
            translated.append(try await service.generate(instructions: instructions, prompt: chunk.text))
        }
        progress(AIProgress(completed: chunks.count, total: chunks.count, message: "Done"))
        return translated.joined(separator: "\n\n")
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
}
