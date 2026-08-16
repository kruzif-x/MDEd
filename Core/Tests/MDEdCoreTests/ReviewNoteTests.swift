import Foundation
import Testing
@testable import MDEdCore

@Suite("ReviewNote")
struct ReviewNoteTests {

    // MARK: - Anchor creation

    @Test func makeAnchorRecordsTextAndBoundedContext() {
        let document = "PREFIX " + String(repeating: "x", count: 200) + " SELECTION " + String(repeating: "y", count: 200)
        let ns = document as NSString
        let selectionRange = ns.range(of: "SELECTION")
        let anchor = NoteAnchorResolver.makeAnchor(
            selection: TextRange(lowerBound: selectionRange.location, upperBound: selectionRange.location + selectionRange.length),
            in: document
        )
        #expect(anchor != nil)
        #expect(anchor?.text == "SELECTION")
        #expect(anchor?.originalRange.lowerBound == selectionRange.location)
        // Both context windows are clipped to the fixed budget, not to the whole document.
        #expect(anchor?.contextBefore.utf16.count == NoteAnchorResolver.contextUTF16Length)
        #expect(anchor?.contextAfter.utf16.count == NoteAnchorResolver.contextUTF16Length)
        // And context + text + context is exactly the document slice the selection sat in.
        let assembled = (anchor?.contextBefore ?? "") + (anchor?.text ?? "") + (anchor?.contextAfter ?? "")
        let beforeLength = ((anchor?.contextBefore ?? "") as NSString).length
        let assembledRange = NSRange(location: selectionRange.location - beforeLength, length: (assembled as NSString).length)
        #expect(ns.substring(with: assembledRange) == assembled)
    }

    @Test func makeAnchorClampsContextAtDocumentEdges() {
        let length = ("selected" as NSString).length
        let anchorAtStart = NoteAnchorResolver.makeAnchor(selection: TextRange(lowerBound: 0, upperBound: length), in: "selected text here")
        #expect(anchorAtStart?.contextBefore == "")
        #expect(anchorAtStart?.contextAfter == " text here")

        let anchorAtEnd = NoteAnchorResolver.makeAnchor(selection: TextRange(lowerBound: 0, upperBound: length), in: "selected")
        #expect(anchorAtEnd?.contextBefore == "")
        #expect(anchorAtEnd?.contextAfter == "")
    }

    @Test func makeAnchorRejectsEmptyAndWhitespaceSelections() {
        #expect(NoteAnchorResolver.makeAnchor(selection: TextRange(lowerBound: 0, upperBound: 0), in: "text") == nil)
        #expect(NoteAnchorResolver.makeAnchor(selection: TextRange(lowerBound: 0, upperBound: 3), in: " \n ") == nil)
        #expect(NoteAnchorResolver.makeAnchor(selection: TextRange(lowerBound: 0, upperBound: 3), in: "abc") != nil)
    }

    @Test func makeAnchorClampsOutOfRangeSelectionsIntoBounds() {
        // An out-of-bounds range (stale offsets handed in by a caller) clamps rather than traps.
        let anchor = NoteAnchorResolver.makeAnchor(selection: TextRange(lowerBound: 2, upperBound: 10_000), in: "abcdef")
        #expect(anchor?.text == "cdef")
    }

    // MARK: - Resolution: exact

    @Test func uneditedDocumentResolvesExact() {
        let document = "# Heading\n\nFirst paragraph is here.\n\nSecond paragraph."
        let ns = document as NSString
        let target = ns.range(of: "First paragraph")
        let anchor = NoteAnchorResolver.makeAnchor(
            selection: TextRange(lowerBound: target.location, upperBound: target.location + target.length),
            in: document
        )!

        let resolution = NoteAnchorResolver.resolve(anchor, in: document)
        #expect(resolution == .exact(TextRange(lowerBound: target.location, upperBound: target.location + target.length)))
    }

    @Test func insertionAbovePassageStillResolvesExactAtNewOffset() {
        let original = "one\nThe quick brown fox\nthree"
        let ns = original as NSString
        let target = ns.range(of: "quick brown")
        let anchor = NoteAnchorResolver.makeAnchor(
            selection: TextRange(lowerBound: target.location, upperBound: target.location + target.length),
            in: original
        )!

        // Twenty new lines above the passage: every stored offset is stale, but the passage
        // and its immediate surroundings are intact — that's exact, not relocated.
        let edited = String(repeating: "new line\n", count: 20) + original
        let resolution = NoteAnchorResolver.resolve(anchor, in: edited)
        let editedNS = edited as NSString
        let newTarget = editedNS.range(of: "quick brown")
        #expect(resolution == .exact(TextRange(lowerBound: newTarget.location, upperBound: newTarget.location + newTarget.length)))
    }

    @Test func uniqueContextDisambiguatesDuplicatedPassage() {
        // "sentence" occurs twice; only the second copy's *surroundings* match the anchor's.
        let document = "alpha sentence beta\nmiddle filler\nprefix sentence suffix"
        let ns = document as NSString
        let second = ns.range(of: "prefix sentence suffix")
        let anchor = NoteAnchorResolver.makeAnchor(
            selection: TextRange(lowerBound: second.location + ("prefix " as NSString).length,
                                 upperBound: second.location + ("prefix sentence" as NSString).length),
            in: document
        )!

        let resolution = NoteAnchorResolver.resolve(anchor, in: document)
        let expected = TextRange(lowerBound: second.location + ("prefix " as NSString).length,
                                 upperBound: second.location + ("prefix sentence" as NSString).length)
        #expect(resolution == .exact(expected))
    }

    // MARK: - Resolution: relocated

    @Test func editedSurroundingsDemoteToRelocated() {
        let original = "lead-in words target passage trailing words"
        let ns = original as NSString
        let target = ns.range(of: "target passage")
        let anchor = NoteAnchorResolver.makeAnchor(
            selection: TextRange(lowerBound: target.location, upperBound: target.location + target.length),
            in: original
        )!

        // Rewrite the text immediately *around* the passage (inside the 64-unit context
        // window) without touching the passage itself.
        let edited = original.replacingOccurrences(of: "lead-in words", with: "different lead-in!")
        let resolution = NoteAnchorResolver.resolve(anchor, in: edited)
        let editedNS = edited as NSString
        let newTarget = editedNS.range(of: "target passage")
        #expect(resolution == .relocated(TextRange(lowerBound: newTarget.location, upperBound: newTarget.location + newTarget.length)))
    }

    // MARK: - Resolution: ambiguous / unmatched

    @Test func duplicatedPassageBecomesAmbiguous() {
        // A note whose original surroundings no longer exist anywhere (stage 1 can't match),
        // resolved against a document where the passage itself now occurs twice: picking an
        // occurrence would be a guess, so the honest answer is ambiguous. Note that a mere
        // *copy* of a still-intact noted passage is NOT ambiguous — the original's intact
        // context still identifies it — which `uneditedDocumentResolvesExact` and
        // `uniqueContextDisambiguatesDuplicatedPassage` above pin from the other side.
        let original = "aaa passage bbb"
        let ns = original as NSString
        let target = ns.range(of: "passage")
        let anchor = NoteAnchorResolver.makeAnchor(
            selection: TextRange(lowerBound: target.location, upperBound: target.location + target.length),
            in: original
        )!

        let edited = "zzz passage yyy tail zzz passage yyy tail"
        let resolution = NoteAnchorResolver.resolve(anchor, in: edited)
        guard case .ambiguous(let candidates) = resolution else {
            Issue.record("expected ambiguous, got \(resolution)")
            return
        }
        #expect(candidates.count == 2)
        let editedNS = edited as NSString
        let occurrences = candidates.map { editedNS.substring(with: $0.nsRange) }
        #expect(occurrences == ["passage", "passage"])
    }

    @Test func ambiguousCandidatesAreCapped() {
        let document = Array(repeating: "dup", count: 40).joined(separator: "\n")
        let anchor = NoteAnchorResolver.makeAnchor(selection: TextRange(lowerBound: 0, upperBound: 3), in: document)!
        // First-line anchor with empty context: contextAfter is 64 units, so the full-context
        // needle itself repeats — either way the outcome must be ambiguous, never exact.
        let resolution = NoteAnchorResolver.resolve(anchor, in: document)
        guard case .ambiguous(let candidates) = resolution else {
            Issue.record("expected ambiguous, got \(resolution)")
            return
        }
        #expect(candidates.count <= NoteAnchorResolver.maxAmbiguousCandidates)
    }

    @Test func deletedPassageIsUnmatched() {
        let original = "before\nthe noted passage\nafter"
        let ns = original as NSString
        let target = ns.range(of: "the noted passage")
        let anchor = NoteAnchorResolver.makeAnchor(
            selection: TextRange(lowerBound: target.location, upperBound: target.location + target.length),
            in: original
        )!

        let resolution = NoteAnchorResolver.resolve(anchor, in: "before\ncompletely rewritten\nafter")
        #expect(resolution == .unmatched)
    }

    @Test func emptyAnchorTextIsUnmatched() {
        let anchor = NoteAnchor(text: "", contextBefore: "a", contextAfter: "b", originalRange: TextRange(lowerBound: 0, upperBound: 0))
        #expect(NoteAnchorResolver.resolve(anchor, in: "abc") == .unmatched)
    }

    // MARK: - Resolution helpers

    @Test func primaryRangeFollowsResolutionState() {
        let range = TextRange(lowerBound: 3, upperBound: 9)
        #expect(NoteAnchorResolution.exact(range).primaryRange == range)
        #expect(NoteAnchorResolution.relocated(range).primaryRange == range)
        #expect(NoteAnchorResolution.ambiguous([range, TextRange(lowerBound: 20, upperBound: 26)]).primaryRange == range)
        #expect(NoteAnchorResolution.unmatched.primaryRange == nil)
    }

    // MARK: - Unicode discipline

    @Test func emojiSelectionKeepsUTF16Offsets() {
        // "😀" is 2 UTF-16 code units, "文" is 1 — an anchored selection containing both must
        // resolve to ranges that, read back as substrings, are exactly the selection.
        let document = "😀 intro 文字 middle 😀 文字 tail"
        let ns = document as NSString
        let target = ns.range(of: "middle 😀 文字")
        #expect(target.location != NSNotFound)
        let anchor = NoteAnchorResolver.makeAnchor(
            selection: TextRange(lowerBound: target.location, upperBound: target.location + target.length),
            in: document
        )!

        let resolution = NoteAnchorResolver.resolve(anchor, in: document)
        guard case .exact(let resolved) = resolution else {
            Issue.record("expected exact, got \(resolution)")
            return
        }
        #expect(ns.substring(with: resolved.nsRange) == "middle 😀 文字")
    }

    @Test func relocatedEmojiSelectionKeepsUTF16Offsets() {
        let document = "😀 alpha 中间 beta"
        let ns = document as NSString
        let target = ns.range(of: "中间")
        let anchor = NoteAnchorResolver.makeAnchor(
            selection: TextRange(lowerBound: target.location, upperBound: target.location + target.length),
            in: document
        )!

        let edited = "changed context 中间 beta"
        let resolution = NoteAnchorResolver.resolve(anchor, in: edited)
        guard case .relocated(let resolved) = resolution else {
            Issue.record("expected relocated, got \(resolution)")
            return
        }
        let editedNS = edited as NSString
        #expect(editedNS.substring(with: resolved.nsRange) == "中间")
    }

    // MARK: - Sidecar container

    @Test func sidecarRoundTripsThroughJSON() throws {
        let document = "context context context anchored passage trailing"
        let ns = document as NSString
        let target = ns.range(of: "anchored passage")
        let anchor = NoteAnchorResolver.makeAnchor(
            selection: TextRange(lowerBound: target.location, upperBound: target.location + target.length),
            in: document
        )!
        let collection = ReviewNoteCollection(notes: [
            ReviewNote(text: "Tighten this.", anchor: anchor, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        ])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(ReviewNoteCollection.self, from: try encoder.encode(collection))
        #expect(decoded.isReadable)
        #expect(decoded.notes.count == 1)
        #expect(decoded.notes[0].id == collection.notes[0].id)
        #expect(decoded.notes[0].text == "Tighten this.")
        #expect(decoded.notes[0].anchor == anchor)
        #expect(decoded.notes[0].createdAt == collection.notes[0].createdAt)
    }

    @Test func missingFieldsDecodeAsEmptyButNotReadable() throws {
        // A foreign or truncated JSON file must not throw — it decodes to an empty, explicitly
        // unreadable collection the caller can distinguish from "zero notes".
        let decoded = try JSONDecoder().decode(ReviewNoteCollection.self, from: Data("{}".utf8))
        #expect(decoded.notes.isEmpty)
        #expect(!decoded.isReadable)
    }
}
