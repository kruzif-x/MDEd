import Cocoa

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

    let textContentStorage = NSTextContentStorage()

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
        textContentStorage.textStorage = NSTextStorage(string: string)
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
    func makeTextContainer(size: NSSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)) -> NSTextContainer {
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: size)
        layoutManager.textContainer = container
        textContentStorage.addTextLayoutManager(layoutManager)
        return container
    }
}
