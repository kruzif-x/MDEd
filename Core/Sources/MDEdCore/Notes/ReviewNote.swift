import Foundation

/// One reviewer's note attached to a passage of a Markdown document, in the spirit of
/// [revdown](https://github.com/Roenbaeck/revdown): the document itself stays byte-for-byte
/// unchanged — the note lives in a sidecar file next to it — and the note's *anchor* is what
/// lets it survive later edits of the document.
///
/// An anchor stores the exact selected text plus a little surrounding context. Re-resolving
/// the anchor against the current document text (see `NoteAnchorResolver`) yields one of four
/// drift states, in order of declining confidence:
///
/// - **exact** — the passage *and* its recorded surroundings are still present, uniquely.
///   The note may have moved to a different offset (text inserted above it shifts it down)
///   without losing confidence: what matters is that passage-plus-context still matches.
/// - **relocated** — the passage text itself still occurs exactly once, but its recorded
///   surroundings no longer match (the text adjacent to the passage was edited).
/// - **ambiguous** — the passage text now occurs more than once, so which occurrence the note
///   belongs to can't be determined mechanically.
/// - **unmatched** — the passage text no longer occurs at all.
///
/// This conservative, honest escalation — rather than silently re-attaching a note to
/// "wherever the text now sort of looks right" — is the whole point of the feature: a note
/// that has drifted should *say so* and ask the user, never guess quietly.
public struct ReviewNote: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    /// The reviewer's comment itself. Free-form Markdown; the editor never interprets it.
    public var text: String
    public var anchor: NoteAnchor
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, anchor: NoteAnchor, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.anchor = anchor
        self.createdAt = createdAt
    }
}

/// Everything needed to re-find a noted passage in a possibly-edited document: the exact
/// selected text at note-creation time, a bounded window of context on either side, and the
/// original UTF-16 range (kept for display/debugging only — resolution never trusts it,
/// because text inserted above the passage makes every stored offset stale).
public struct NoteAnchor: Sendable, Codable, Equatable {
    /// The exact text that was selected when the note was created, verbatim.
    public var text: String
    /// Up to `NoteAnchorResolver.contextUTF16Length` code units of document text immediately
    /// before the selection (clamped to the document start). Empty when the selection began
    /// the document or shared its opening with the context window's edge.
    public var contextBefore: String
    /// Up to `NoteAnchorResolver.contextUTF16Length` code units immediately after the
    /// selection, clamped to the document end.
    public var contextAfter: String
    /// Where the selection was when the note was created. Informational only — never a
    /// participant in resolution, for the reason this type's doc comment gives.
    public var originalRange: TextRange

    public init(text: String, contextBefore: String, contextAfter: String, originalRange: TextRange) {
        self.text = text
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.originalRange = originalRange
    }
}

/// The versioned sidecar container written next to a document (`notes.md.mded-notes.json`),
/// decoupled from any future in-app persistence changes by its `format`/`version` stamp.
/// Decoding is the owner's (tolerant) job; this type only states the shape.
public struct ReviewNoteCollection: Sendable, Codable, Equatable {
    public static let formatIdentifier = "mded-notes"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var notes: [ReviewNote]

    public init(notes: [ReviewNote]) {
        self.format = Self.formatIdentifier
        self.version = Self.currentVersion
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A sidecar whose stamp isn't one we wrote decodes as *no* notes rather than failing —
        // an unknown future format must never wedge note loading, and must never be
        // interpreted as "the user deleted all their notes" either: the caller distinguishes
        // the two by checking the stamp itself before deciding to overwrite anything.
        self.format = try container.decodeIfPresent(String.self, forKey: .format) ?? ""
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        self.notes = try container.decodeIfPresent([ReviewNote].self, forKey: .notes) ?? []
    }

    /// `true` when this decoded collection was written by a version of this sidecar format
    /// this build understands and is safe to round-trip without data loss.
    public var isReadable: Bool { format == Self.formatIdentifier && version <= Self.currentVersion }

    private enum CodingKeys: String, CodingKey {
        case format, version, notes
    }
}

// MARK: - Resolution

/// The outcome of re-finding a note's anchor in the current document text — see
/// `ReviewNote`'s doc comment for what each state means and why they escalate the way they do.
public enum NoteAnchorResolution: Sendable, Equatable {
    /// Passage plus recorded context matched uniquely. Carries the passage's current range.
    case exact(TextRange)
    /// Passage text matched uniquely, but its recorded surroundings didn't. Carries the
    /// passage's current range.
    case relocated(TextRange)
    /// Passage text occurs more than once. Carries up to
    /// `NoteAnchorResolver.maxAmbiguousCandidates` of the occurrences, in document order.
    case ambiguous([TextRange])
    /// The passage text doesn't occur at all.
    case unmatched

    /// The single best range to reveal/select for this resolution, if there is one:
    /// the (unique) range for exact/relocated, the *first* candidate for ambiguous — an
    /// explicit choice with an explicit caveat, since the note itself is what's authoritative,
    /// not the location — and nothing for unmatched.
    public var primaryRange: TextRange? {
        switch self {
        case .exact(let range), .relocated(let range):
            return range
        case .ambiguous(let candidates):
            return candidates.first
        case .unmatched:
            return nil
        }
    }
}

/// Pure, stateless anchor creation and re-resolution — the whole "notes survive edits"
/// mechanism in functions the test suite can hammer directly.
public enum NoteAnchorResolver {

    /// How much surrounding text (UTF-16 code units, per side) an anchor records. Enough to
    /// make ordinary sentences unique in practice; small enough that edits to *nearby but not
    /// adjacent* text don't needlessly demote a still-perfectly-findable note to relocated.
    public static let contextUTF16Length = 64

    /// Ambiguous resolutions carry at most this many candidate ranges — a note anchored to a
    /// genuinely common string ("the", "-"…) in a large document shouldn't cart hundreds of
    /// ranges around for UI that can only show a handful anyway. Resolution never searches
    /// past one more occurrence than this: once ambiguity is established, where the 18th copy
    /// sits changes nothing.
    public static let maxAmbiguousCandidates = 16

    /// Builds an anchor for `selection` in `document`, or `nil` if the selection is empty,
    /// out of bounds, or whitespace-only — the three cases where there is no passage to
    /// anchor to and creating a note would only ever produce a permanently-unmatched one.
    public static func makeAnchor(selection: TextRange, in document: String) -> NoteAnchor? {
        let ns = document as NSString
        let lower = max(0, min(selection.lowerBound, ns.length))
        let upper = max(lower, min(selection.upperBound, ns.length))
        guard lower < upper else { return nil }

        let selectedText = ns.substring(with: NSRange(location: lower, length: upper - lower))
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let contextStart = max(0, lower - contextUTF16Length)
        let contextEnd = min(ns.length, upper + contextUTF16Length)
        let before = ns.substring(with: NSRange(location: contextStart, length: lower - contextStart))
        let after = ns.substring(with: NSRange(location: upper, length: contextEnd - upper))

        return NoteAnchor(
            text: selectedText,
            contextBefore: before,
            contextAfter: after,
            originalRange: TextRange(lowerBound: lower, upperBound: upper)
        )
    }

    /// Re-finds `anchor` in `document` — see `ReviewNote`'s doc comment for the state
    /// semantics. Two stages, most-confident first:
    ///
    /// 1. If the anchor carries any context, search for context+passage+context. A unique
    ///    hit is `exact` even at a different offset than `originalRange`: offsets shift for
    ///    innocent reasons (text inserted above), while passage-plus-surroundings intact is
    ///    real evidence the note still points at what it was attached to.
    /// 2. Search for the bare passage. Zero hits is `unmatched`, one is `relocated`, more
    ///    than one is `ambiguous` — never a guess between them.
    public static func resolve(_ anchor: NoteAnchor, in document: String) -> NoteAnchorResolution {
        guard !anchor.text.isEmpty else { return .unmatched }

        if !anchor.contextBefore.isEmpty || !anchor.contextAfter.isEmpty {
            let needle = anchor.contextBefore + anchor.text + anchor.contextAfter
            let fullMatches = occurrences(of: needle, in: document)
            if fullMatches.count == 1, let match = fullMatches.first {
                let textLower = match.lowerBound + (anchor.contextBefore as NSString).length
                return .exact(TextRange(lowerBound: textLower, upperBound: textLower + (anchor.text as NSString).length))
            }
        }

        let textMatches = occurrences(of: anchor.text, in: document)
        switch textMatches.count {
        case 0:
            return .unmatched
        case 1:
            return .relocated(textMatches[0])
        default:
            return .ambiguous(textMatches)
        }
    }

    /// All non-overlapping occurrences of `needle` in `document`, in document order, in UTF-16
    /// offsets. Search stops after `maxAmbiguousCandidates + 1` hits — enough for every
    /// distinction `resolve` needs (zero / exactly one / more than one) without scanning a
    /// pathological document to the end for a count nobody uses.
    private static func occurrences(of needle: String, in document: String) -> [TextRange] {
        let ns = document as NSString
        let needleLength = needle.utf16.count
        guard needleLength > 0, needleLength <= ns.length else { return [] }

        var matches: [TextRange] = []
        var searchStart = 0
        while searchStart <= ns.length - needleLength {
            let found = ns.range(of: needle, range: NSRange(location: searchStart, length: ns.length - searchStart))
            guard found.location != NSNotFound else { break }
            matches.append(TextRange(lowerBound: found.location, upperBound: found.location + needleLength))
            if matches.count >= maxAmbiguousCandidates { break }
            searchStart = found.location + needleLength
        }
        return matches
    }
}
