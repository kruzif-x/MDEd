import Foundation

/// Why on-device AI is (or isn't) usable right now, in terms a user can act on. Never a bare
/// "unavailable" — `.unavailable`'s `explanation` is a complete sentence, ready to show directly
/// in a disabled menu item's tooltip or a review sheet's error state, that says what's true and,
/// where there's something to do about it, what that is.
enum AIAvailability: Equatable {
    case available
    case unavailable(explanation: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// The seam between MDEd's AI commands and whatever actually runs them.
/// `FoundationModelsAIService` is the only implementation this app ships, and is meant to stay the
/// only one — no cloud providers, no API keys, nothing to configure; on-device only, by design, not
/// by current limitation. This protocol exists for two narrower reasons instead:
///
/// 1. It keeps every `import FoundationModels` contained to one file (`FoundationModelsAIService.swift`),
///    so the rest of the app's AI-facing code — `AICommandRunner`, the review UI, the menu wiring —
///    reads and compiles independent of that framework's specific API shape.
/// 2. It gives "the model isn't available" exactly one place to become a value (`AIAvailability`)
///    that a menu item's validation and a command's failure path can both read uniformly, instead
///    of a `do`/`catch` around `SystemLanguageModel` scattered across every call site.
protocol AIService {
    var availability: AIAvailability { get }

    /// Runs one prompt against the model and returns its plain-text response. Each call is a fresh,
    /// one-shot session — none of MDEd's commands need a multi-turn conversation.
    ///
    /// - Parameters:
    ///   - instructions: The system-level framing: what kind of task this is, what to preserve.
    ///   - prompt: The user content — a document, a chunk of one, a selection, a rendered diff.
    func generate(instructions: String, prompt: String) async throws -> String

    /// Like `generate(instructions:prompt:)`, but asks the model for a typed structure (a summary
    /// plus a short list of key points — see `FoundationModelsAIService`'s `@Generable` definition)
    /// instead of free prose, then renders that structure back to plain text.
    ///
    /// Used only for `AICommandRunner.summarizeDocument`'s headingless-document reduce step — the
    /// one place this app asks the model to summarize text that's *already a summary* (see
    /// `AICommandRunner.reduceSummariesGuided`'s doc comment for why that's exactly the case guided
    /// generation helps most: a free-prose reduce pass is what drifts toward generic, repetitive
    /// phrasing on a large document, and a schema the model must fill in pushes back against that
    /// drift instead of leaving it to instruction text alone.
    func generateGuidedSummary(instructions: String, prompt: String) async throws -> String
}

/// The app-wide `AIService` instance. A single shared instance (rather than one per call site)
/// mirrors this codebase's existing style for app-wide state — `EditorSettings.current()` reads a
/// fresh snapshot from one shared store the same way — and means every AI command in the app talks
/// to the same `SystemLanguageModel`-backed session factory without threading a service reference
/// through every view controller's initializer.
enum AIServiceProvider {
    static let shared: AIService = FoundationModelsAIService()
}
