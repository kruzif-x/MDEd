import Cocoa
import MDEdCore

/// Owns one document's review notes: the in-memory list, their re-resolved anchors, and the
/// sidecar file they persist to — `<document>.mded-notes.json`, next to the document, in the
/// revdown tradition of never touching the document itself. See `ReviewNote`/`NoteAnchorResolver`
/// (MDEdCore) for the anchoring model this controller drives.
///
/// The document's *text* is read straight from the shared `NSTextContentStorage`
/// (`document.currentText`) on every recompute, never cached here — so recomputes are always
/// against what the user actually sees, and this controller holds nothing that can drift from
/// the editor. All mutation methods persist immediately and then `recompute()`, which fires
/// `onDidChange` for the editor's presentation pass (text bars, gutter dots, list).
///
/// An unsaved ("Untitled") document has no sidecar URL; its notes live in memory only, and
/// reach disk on the first save after it gains a URL — the editor wires that by calling
/// `persistNow()` on `NSDocument.didSaveNotification`.
@MainActor
final class ReviewNotesController {

    private unowned let document: Document

    private(set) var notes: [ReviewNote] = []
    private(set) var resolutions: [UUID: NoteAnchorResolution] = [:]

    /// Fires after any change to `notes` or `resolutions` — the editor's cue to refresh its
    /// note bars, gutter markers, and any open notes popover.
    var onDidChange: (() -> Void)?

    /// The last note list actually written to (or removed from) the sidecar, so saving an
    /// unchanged document (autosave fires `persistNow` regularly) doesn't rewrite identical
    /// JSON on every pass.
    private var lastPersistedNotes: [ReviewNote]?

    /// `true` when a sidecar file exists but wasn't in a format this build reads (unknown
    /// `format`/`version` stamp, or undecodable JSON). Such a file is presumed to belong to a
    /// newer MDEd: its notes aren't loaded, and — the actual point of the flag — `persist()`
    /// refuses to write either, because the one thing worse than ignoring a newer sidecar is
    /// silently destroying it.
    private var sidecarIsForeign = false

    init(document: Document) {
        self.document = document
    }

    var hasNotes: Bool { !notes.isEmpty }

    /// `file.md` → `file.md.mded-notes.json`, in the same directory.
    var sidecarURL: URL? {
        document.fileURL.map { URL(fileURLWithPath: $0.path + ".mded-notes.json") }
    }

    // MARK: - Loading

    /// Reads the sidecar (if any) and re-resolves every anchor against the current text.
    /// Tolerant by design: a missing, corrupt, or foreign sidecar means "no notes", never an
    /// error and never a reason to mark the document edited.
    func reloadFromSidecar() {
        guard let url = sidecarURL, let data = try? Data(contentsOf: url) else {
            notes = []
            lastPersistedNotes = notes
            sidecarIsForeign = false
            recompute()
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let collection = try? decoder.decode(ReviewNoteCollection.self, from: data), collection.isReadable {
            notes = collection.notes
            sidecarIsForeign = false
        } else {
            notes = []
            sidecarIsForeign = true
        }
        lastPersistedNotes = notes
        recompute()
    }

    // MARK: - Mutation

    /// Anchors a new note to `selection`. Fails (returning `false`, changing nothing) when the
    /// note text is empty or the selection can't be anchored — the same conditions
    /// `NoteAnchorResolver.makeAnchor` rejects; callers use the result to keep UI honest.
    @discardableResult
    func addNote(_ text: String, selection: MDEdCore.TextRange) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let anchor = NoteAnchorResolver.makeAnchor(selection: selection, in: document.currentText)
        else { return false }
        notes.append(ReviewNote(text: trimmed, anchor: anchor))
        persist()
        recompute()
        return true
    }

    func updateNote(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].text = trimmed
        persist()
        // The anchor — and therefore every resolution — is unchanged by an edit; only the
        // displayed text needs refreshing.
        onDidChange?()
    }

    func removeNote(id: UUID) {
        notes.removeAll { $0.id == id }
        persist()
        recompute()
    }

    func removeAllNotes() {
        notes.removeAll()
        persist()
        recompute()
    }

    // MARK: - Resolution

    /// Re-resolves every note's anchor against the document's current text. The editor calls
    /// this from its existing restyle debounce, so notes track edits with the same cadence
    /// styling does — never on every keystroke, never stale for long.
    func recompute() {
        let text = document.currentText
        var next: [UUID: NoteAnchorResolution] = [:]
        next.reserveCapacity(notes.count)
        for note in notes {
            next[note.id] = NoteAnchorResolver.resolve(note.anchor, in: text)
        }
        resolutions = next
        onDidChange?()
    }

    func note(id: UUID) -> ReviewNote? {
        notes.first { $0.id == id }
    }

    func resolution(for id: UUID) -> NoteAnchorResolution {
        resolutions[id] ?? .unmatched
    }

    /// The best range to select/reveal for a note — see `NoteAnchorResolution.primaryRange`
    /// for why ambiguous picks a first candidate and unmatched picks none.
    func primaryRange(for id: UUID) -> MDEdCore.TextRange? {
        resolution(for: id).primaryRange
    }

    // MARK: - Presentation payloads

    /// Gutter dots: which notes *start* on which source line (0-based, per `lines`). A note
    /// spanning several lines gets its dot on the first — consistent with the gutter's
    /// existing "this construct starts here" policy for collapsed blocks.
    func gutterMarkers(in lines: DocumentLines) -> [Int: [NoteMarker]] {
        var markers: [Int: [NoteMarker]] = [:]
        for note in notes {
            guard let range = primaryRange(for: note.id),
                  let line = lines.lineIndex(atUTF16Offset: range.lowerBound)
            else { continue }
            markers[line, default: []].append(NoteMarker(noteID: note.id, kind: NoteStatusKind(resolution(for: note.id))))
        }
        return markers
    }

    /// Text-column bars: one per note with a resolvable location. Unmatched notes are
    /// deliberately absent — they have no location to paint — and stay reachable through the
    /// notes list.
    func highlightRanges() -> [NoteHighlight] {
        notes.compactMap { note in
            guard let range = primaryRange(for: note.id) else { return nil }
            return NoteHighlight(range: range.nsRange, kind: NoteStatusKind(resolution(for: note.id)))
        }
    }

    // MARK: - Persistence

    /// Writes the sidecar if (and only if) the note list changed since the last write. Public
    /// for the editor's `NSDocument.didSaveNotification` hook, which is what carries notes
    /// made in an unsaved document to disk the moment it first gets a URL.
    func persistNow() {
        persist()
    }

    private func persist() {
        guard let url = sidecarURL else { return }
        guard !sidecarIsForeign else {
            // See `sidecarIsForeign`: never overwrite a file this build doesn't understand.
            return
        }
        guard notes != lastPersistedNotes else { return }

        if notes.isEmpty {
            // The last note was deleted — remove the sidecar rather than leaving a husk
            // (or, worse, a "notes: []" file a future version would have to treat as data).
            try? FileManager.default.removeItem(at: url)
            lastPersistedNotes = notes
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // A failed write (read-only directory, full disk) leaves `lastPersistedNotes` stale,
        // so the next mutation retries — notes stay live in memory either way.
        if let data = try? encoder.encode(ReviewNoteCollection(notes: notes)),
           (try? data.write(to: url, options: .atomic)) != nil {
            lastPersistedNotes = notes
        }
    }
}
