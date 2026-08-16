import Cocoa
import MDEdCore

/// A plain UTF-8 text document — Markdown (`.md`/`.markdown`) or `.txt`.
///
/// `textContentStorage` is the single source of truth for this document's text, from the moment
/// it's created (a brand-new empty document, or a file finished loading) for as long as it stays
/// open. Every text view that displays this document — the normal editor tab's `EditorViewController`,
/// and (if it's also open there) a comparison window's pane — attaches its own `NSTextLayoutManager`
/// to this same `NSTextContentStorage` via `makeTextContainer()` rather than owning an independent
/// copy of the text. That is deliberate, not incidental: `NSDocumentController` guarantees one
/// `Document` instance per URL, but that guarantee is only useful if every view of that URL reads
/// and writes through the *same* text storage. Two independent `NSTextStorage`s for one document —
/// one per view — would silently diverge the moment either was edited, and whichever `data(ofType:)`
/// happened to run at save time would win, discarding the other view's edits with no warning. With
/// one shared storage, "two views of the same document" is trivially, structurally impossible to
/// get wrong: there is only ever one piece of text to save.
final class Document: NSDocument {

    /// Posted after every successful save (explicit ⌘S, autosave-in-place, Save As…) — the
    /// hook review notes use to reach the sidecar the moment an unsaved document first gets
    /// a real `fileURL`. Modern AppKit exposes no public did-save notification, hence this
    /// own-name one, posted from the `save(to:…)` override below (the funnel every kind of
    /// save goes through).
    static let didSaveMDEdNotification = Notification.Name("MDEdDocumentDidSave")

    let textContentStorage = NSTextContentStorage()

    /// How many `ComparePaneViewController`s currently have this document open — incremented in
    /// `ComparePaneViewController.init`, decremented in its `deinit`.
    ///
    /// This exists solely so live-preview marker hiding can refuse to run whenever it would be
    /// unsafe. `EditorViewController` and `ComparePaneViewController` both attach their own
    /// `NSTextLayoutManager` to this *same* shared `textContentStorage` (see this type's own doc
    /// comment for why the sharing itself is deliberate) — but `NSTextContentStorageDelegate` is a
    /// single property on the content storage, not one per layout manager, and the paragraph
    /// objects it produces are cached and handed to *every* attached layout manager alike. There is
    /// no way for one delegate to show hidden markers to the editor's layout manager while showing
    /// full styled source to a compare pane's layout manager on the same content storage at the
    /// same time — the paragraph object is the same object either way.
    ///
    /// That collision is only reachable when the *same* file is open both as an ordinary editor tab
    /// and inside a comparison window (comparing a document against itself, or a document already
    /// open elsewhere) — `NSDocumentController` dedupes by URL, so this is the only way two
    /// different views end up sharing one `Document`. Rather than accept silently-wrong behavior in
    /// that case, `LivePreviewController` checks `hasComparePane` before hiding anything and turns
    /// hiding off for the *whole* document for as long as it's true, falling back to the exact
    /// styled-source rendering compare mode requires. Correctness for compare wins over live
    /// preview being available in this narrow, rare, dual-view case; see this project's README/PR
    /// notes for why a private duplicate content storage for the editor was rejected instead (it
    /// would reintroduce the two-independent-text-storages divergence risk this type's own doc
    /// comment describes).
    private(set) var comparePaneAttachmentCount = 0

    var hasComparePane: Bool { comparePaneAttachmentCount > 0 }

    func attachComparePane() { comparePaneAttachmentCount += 1 }

    func detachComparePane() { comparePaneAttachmentCount = max(0, comparePaneAttachmentCount - 1) }

    override init() {
        super.init()
        // A brand-new (File > New) document has no `read(from:ofType:)` call to populate this, so
        // it needs an explicit empty starting point — any view that attaches afterward should
        // always find real (if empty) text, never `nil`.
        textContentStorage.textStorage = NSTextStorage(string: "")
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let windowController = DocumentWindowController(document: self)
        addWindowController(windowController)
        windowController.editorViewController.finishInitialSetup()
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadCorruptFileError,
                userInfo: [NSLocalizedDescriptionKey: "The file couldn’t be opened because it isn’t valid UTF-8 text."]
            )
        }

        // A *live* re-read (Revert to Saved, or NSDocumentController reopening a file that
        // changed on disk into its already-open Document) must never swap in a brand-new
        // `NSTextStorage`: every attached view — this document's editor tab, a comparison
        // window's pane — registered itself against the *existing* instance, and no
        // `NSTextViewDelegate.textDidChange` fires for a swap, so styling, live preview,
        // outline, notes, and any open diff would all keep describing the pre-revert text
        // until the next keystroke. Mutating the shared storage in place instead posts an
        // ordinary edit through the normal TextKit machinery: views re-render, and the
        // `.editedCharacters` storage notification each view controller observes (see
        // `EditorViewController.observeStorageEdits()` / `CompareViewController`) re-derives
        // all of that state on the same debounce a keystroke would have.
        //
        // "Is this document live" is answered precisely by the shared content storage's
        // attached layout managers: `makeTextContainer()` is exactly what adds one, so an
        // empty list means no view exists yet — the ordinary first-open path, where a plain
        // assignment is still the right (cheaper) move.
        if let storage = textContentStorage.textStorage, !textContentStorage.textLayoutManagers.isEmpty {
            // Wrapped per this project's undo/dirty-flag discipline: a programmatic storage
            // edit left unwrapped would register an undo action and mark the just-reverted
            // document edited again (see `withoutRegisteringUndo`'s doc comment). The plain
            // `NSAttributedString` (no attributes) rather than a bare `String` is deliberate:
            // a bare-string replace inherits the replaced range's opening attributes, so the
            // whole reverted document would briefly carry whatever font/weight the old first
            // character had.
            withoutRegisteringUndo(on: undoManager) {
                let fullRange = NSRange(location: 0, length: storage.length)
                storage.replaceCharacters(in: fullRange, with: NSAttributedString(string: string))
            }
        } else {
            textContentStorage.textStorage = NSTextStorage(string: string)
        }
    }

    /// Revert means "discard everything since the last save" — including the ability to
    /// undo back into it. `super` re-reads the saved contents (landing in `read(from:)`
    /// above, in-place for a live document); this defensive clear guarantees no pre-revert
    /// undo group can ever be replayed onto the reverted text, whose ranges no longer mean
    /// what those groups recorded (idempotent if `super` already cleared the stack).
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        undoManager?.removeAllActions()
    }

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            completionHandler(error)
            if error == nil {
                NotificationCenter.default.post(name: Document.didSaveMDEdNotification, object: self)
            }
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        let text = textContentStorage.textStorage?.string ?? ""
        guard let data = text.data(using: .utf8) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: "The document’s text couldn’t be converted to UTF-8."]
            )
        }
        return data
    }

    /// The document's current text, read straight from the shared storage — always up to date
    /// regardless of which view(s), if any, last edited it.
    var currentText: String { textContentStorage.textStorage?.string ?? "" }

    /// Creates a new TextKit 2 layout manager + container attached to `textContentStorage`, so a
    /// text view built with the returned container shows (and can edit) exactly this document's
    /// text — see this type's documentation for why that sharing is the point.
    ///
    /// Returns the container alongside the `TextLayoutAttachment` that owns detaching its layout
    /// manager again. The caller (an `EditorViewController` or `ComparePaneViewController`) must
    /// hold that attachment for as long as it uses the container — typically as a stored
    /// property — so the layout manager detaches automatically when that view controller
    /// deallocates, instead of staying attached to this document's shared `textContentStorage`
    /// forever. See `TextLayoutAttachment`'s doc comment for the leak this fixes.
    func makeTextContainer(
        size: NSSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    ) -> (container: NSTextContainer, attachment: TextLayoutAttachment) {
        let attachment = TextLayoutAttachment(attachingTo: textContentStorage)
        let container = NSTextContainer(size: size)
        attachment.layoutManager.textContainer = container
        return (container, attachment)
    }
}
