import Foundation

/// The Markdown markup an AI response introduced beyond what its source had — see
/// `MarkupComparator.delta(source:result:)`.
public struct MarkupDelta: Sendable, Equatable {
    /// The syntax kinds that appear *more often* in the result than in the source, one entry per
    /// kind (never one entry per occurrence) — a response that added two bold runs where the
    /// source had none reports `[.strong]` once, not twice.
    public let introduced: [SyntaxKind]

    public var hasChanges: Bool { !introduced.isEmpty }

    public init(introduced: [SyntaxKind]) {
        self.introduced = introduced
    }
}

/// Checks whether an AI response preserved a source's Markdown markup exactly, for any command
/// that promises to (Tighten Selection, Translate) — see this project's own principle: don't ask
/// the model to guarantee what a tested parser can verify directly. `Tighten Selection` has been
/// observed adding `**bold**` around plain words despite an explicit instruction not to; this
/// exists so that drift is caught mechanically rather than trusted away.
///
/// Deliberately a **count-per-kind** comparison, not a structural diff: it answers "did the result
/// have more of some markup kind than the source did", which is exactly what "the model added
/// formatting that wasn't there" means, without requiring the source and result to align
/// position-for-position (translation reorders and resizes text; a position-sensitive diff would
/// misfire on that alone). It does not flag markup the result *removed* — only a command that
/// promises preservation cares about this at all, and dropping formatting is a different failure
/// mode this isn't built to catch.
public enum MarkupComparator {

    /// Compares the Markdown syntax elements `syntaxMap(of:)` finds in `source` and `result`,
    /// returning every kind that appears more often in `result`.
    public static func delta(source: String, result: String) -> MarkupDelta {
        let sourceCounts = countsByKind(syntaxMap(of: source))
        let resultCounts = countsByKind(syntaxMap(of: result))

        var introduced: [SyntaxKind] = []
        for element in syntaxMap(of: result) {
            let kind = element.kind
            guard !introduced.contains(kind) else { continue }
            let resultCount = resultCounts[kind] ?? 0
            let sourceCount = sourceCounts[kind] ?? 0
            if resultCount > sourceCount {
                introduced.append(kind)
            }
        }
        return MarkupDelta(introduced: introduced)
    }

    private static func countsByKind(_ elements: [SyntaxElement]) -> [SyntaxKind: Int] {
        var counts: [SyntaxKind: Int] = [:]
        for element in elements {
            counts[element.kind, default: 0] += 1
        }
        return counts
    }
}
