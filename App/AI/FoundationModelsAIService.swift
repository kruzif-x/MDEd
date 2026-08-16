import FoundationModels
import Foundation

/// The only `AIService` implementation MDEd ships: Apple's on-device Foundation Models. Entirely
/// local — no network request ever leaves the machine, no API key, nothing to configure. See
/// `AIService`'s doc comment for why the app is built against a protocol at all when there's
/// exactly one implementation of it.
final class FoundationModelsAIService: AIService {

    var availability: AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(explanation: explanation(for: reason))
        }
    }

    func generate(instructions: String, prompt: String) async throws -> String {
        // A fresh session per call — every command here is one-shot, not a conversation, so there's
        // no reason to keep a session (and its growing transcript) alive between calls.
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw AIServiceError(generationError: error)
        }
    }

    func generateGuidedSummary(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, generating: GuidedSummary.self)
            return response.content.rendered
        } catch let error as LanguageModelSession.GenerationError {
            throw AIServiceError(generationError: error)
        }
    }

    // MARK: - Unavailability reasons

    /// Turns FoundationModels' own `UnavailableReason` into a sentence a user can act on — see
    /// `AIAvailability`'s doc comment for why this app never surfaces a bare "unavailable".
    private func explanation(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac doesn’t support Apple Intelligence, so on-device AI features aren’t available here."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings ▸ Apple Intelligence & Siri to use these features."
        case .modelNotReady:
            return "The on-device model is still downloading. These features will work once it finishes — try again shortly."
        @unknown default:
            return "On-device AI isn’t available right now."
        }
    }
}

/// The typed structure `generateGuidedSummary(instructions:prompt:)` asks the model to fill in
/// instead of free prose — see that method's doc comment on `AIService` for why. `@Generable`
/// guides the model to produce exactly these two fields rather than whatever shape free-form prose
/// happens to take, which is the whole point on a reduce pass over already-summarized text: a
/// schema resists the "designed to be user-friendly… designed to be accessible…" drift a plain
/// prompt doesn't reliably prevent.
@Generable
struct GuidedSummary: Sendable {
    @Guide(description: "A concise, plain-language summary of the whole document, two to four sentences, no Markdown formatting.")
    var summary: String

    @Guide(description: "The document's main topics, as short plain-language phrases (not full sentences, no Markdown), three to six items, in the document's own order.")
    var keyPoints: [String]

    /// Flattens the two fields back into the plain text every other AI command in this app returns
    /// — the review sheet and the "insert at cursor" apply path both expect plain text, not a
    /// structure, so this is where that structure's fields get turned back into it.
    var rendered: String {
        guard !keyPoints.isEmpty else { return summary }
        let points = keyPoints.map { "- \($0)" }.joined(separator: "\n")
        return "\(summary)\n\n\(points)"
    }
}

/// A friendlier error surface than raw `LanguageModelSession.GenerationError` for the review UI.
/// Most of that enum's cases are internal/diagnostic; the one a user actually needs explained —
/// `exceededContextWindowSize`, which can still happen for a single selection/section too large to
/// fit even after chunking — gets its own message here. Everything else falls back to the
/// framework's own `errorDescription`.
struct AIServiceError: Error, LocalizedError {
    let errorDescription: String?

    init(generationError: LanguageModelSession.GenerationError) {
        switch generationError {
        case .exceededContextWindowSize:
            errorDescription = "This passage is too large for on-device AI to process in one piece. Try a shorter selection."
        case .guardrailViolation:
            errorDescription = "On-device AI declined to process this content."
        default:
            errorDescription = generationError.errorDescription ?? "On-device AI couldn’t complete this request."
        }
    }
}
