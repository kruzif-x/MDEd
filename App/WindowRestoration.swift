import Cocoa

/// The concrete `NSWindow` every `DocumentWindowController` creates. Its only job beyond being a
/// plain window is knowing, at the moment AppKit asks it to save restorable state (typically at
/// quit), which document it currently belongs to — see `encodeRestorableState(with:)`.
///
/// A `weak` reference, not a captured `URL?` snapshotted at init time: reading `mdedDocument?.fileURL`
/// fresh on every encode means a document that starts as "Untitled" and is later saved (or
/// Save-As'd to a different location) is described correctly the *next* time state is saved, with
/// no extra wiring needed to keep a cached value in sync.
final class MDEdDocumentWindow: NSWindow {
    weak var mdedDocument: Document?

    static let documentFileURLRestorationKey = "MDEdDocumentFileURL"

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(mdedDocument?.fileURL as NSURL?, forKey: Self.documentFileURLRestorationKey)
    }
}

/// Reopens one document's window from AppKit's secure state restoration ("Resume") at the next
/// launch — the `window.restorationClass` every `DocumentWindowController` installs on its window
/// (see that type). AppKit calls this once per restorable window that was open when the app last
/// quit, before any document or window exists yet; `state` is exactly what
/// `MDEdDocumentWindow.encodeRestorableState(with:)` wrote for that window at quit time, so the
/// document's file URL is read straight out of it rather than needing to guess it from
/// `identifier` (which exists only to give AppKit a stable per-window key, not to carry payload).
///
/// A document with no file URL at quit time (a never-saved "Untitled" window) encodes `nil` and is
/// silently not restored here — there is no file to reopen it from, and reconstructing unsaved text
/// from nothing but restorable state is out of scope for this pass. That one document's window
/// frame is lost on relaunch; every saved document's window, and its frame, comes back.
final class DocumentWindowRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        guard let url = state.decodeObject(of: NSURL.self, forKey: MDEdDocumentWindow.documentFileURLRestorationKey) as URL?
        else {
            completionHandler(nil, nil)
            return
        }

        // `reopenDocument(for:withContentsOf:display:completionHandler:)` is `NSDocumentController`'s
        // own "open, or return the already-open instance" entry point — it dedupes against a
        // document already opened by an earlier restoration callback in the same relaunch (or
        // opened independently, e.g. via a Finder double-click racing this one), same as any other
        // open path in this app. `display: true` drives `makeWindowControllers()`, which is what
        // actually creates the `DocumentWindowController`/`MDEdDocumentWindow` this method hands
        // back.
        NSDocumentController.shared.reopenDocument(for: nil, withContentsOf: url, display: true) { document, _, error in
            guard let document = document as? Document, let window = document.windowControllers.first?.window else {
                completionHandler(nil, error)
                return
            }
            completionHandler(window, nil)
        }
    }
}
