import Cocoa

/// Owns the document window and its single `EditorViewController`. Native window tabbing is not
/// disabled anywhere here, so it comes free from `NSDocument`/`NSWindow`'s own machinery.
final class DocumentWindowController: NSWindowController {

    let editorViewController = EditorViewController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.setFrameAutosaveName("MDEdDocumentWindow")
        window.minSize = NSSize(width: 480, height: 320)

        self.init(window: window)

        window.contentViewController = editorViewController
        // `synchronizeWindowTitleWithDocumentName` (the NSWindowController default) keeps the
        // title, proxy icon, and edited-dot in sync with the document automatically.
    }
}
