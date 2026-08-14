import Cocoa

/// A plain UTF-8 text document — Markdown (`.md`/`.markdown`) or `.txt`.
///
/// Content ownership is deliberately simple: before a window exists, `Document` holds the text it
/// read from disk in `loadedText`. Once `makeWindowControllers()` runs, the `NSTextView` created by
/// `EditorViewController` becomes the source of truth (standard AppKit document-editor pattern) —
/// `Document` just asks it for the current string when saving.
final class Document: NSDocument {

    private var loadedText: String = ""
    private weak var editorViewController: EditorViewController?

    override init() {
        super.init()
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let windowController = DocumentWindowController()
        addWindowController(windowController)

        let editorVC = windowController.editorViewController
        editorViewController = editorVC
        editorVC.setInitialText(loadedText)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadCorruptFileError,
                userInfo: [NSLocalizedDescriptionKey: "The file couldn’t be opened because it isn’t valid UTF-8 text."]
            )
        }
        loadedText = string
    }

    override func data(ofType typeName: String) throws -> Data {
        let text = editorViewController?.currentText ?? loadedText
        guard let data = text.data(using: .utf8) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: "The document’s text couldn’t be converted to UTF-8."]
            )
        }
        return data
    }
}
