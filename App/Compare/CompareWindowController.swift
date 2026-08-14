import Cocoa

/// Owns the comparison window and its `CompareViewController`. Unlike a normal document window,
/// this window's `.document` is never set — it hosts *two* documents, and `NSWindowController`
/// only ever has one — so none of `NSDocument`'s automatic "prompt to save before closing" wiring
/// applies here. `windowShouldClose(_:)` below is that machinery, reimplemented by hand for the
/// two-document case; see its documentation for the policy.
final class CompareWindowController: NSWindowController, NSWindowDelegate {

    private let compareViewController: CompareViewController
    private var confirmedClose = false

    /// Called once the window has actually closed (after any save prompts resolve), so whoever
    /// presented this window can stop retaining it.
    var onClosed: (() -> Void)?

    init(leftDocument: Document, rightDocument: Document) {
        compareViewController = CompareViewController(leftDocument: leftDocument, rightDocument: rightDocument)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.contentViewController = compareViewController
        window.center()
        window.setFrameAutosaveName("MDEdCompareWindow")
        window.minSize = NSSize(width: 640, height: 420)
        window.title = Self.title(left: leftDocument, right: rightDocument)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — this app has no storyboard/xib")
    }

    private static func title(left: Document, right: Document) -> String {
        let leftName = left.displayName ?? left.fileURL?.lastPathComponent ?? "Untitled"
        let rightName = right.displayName ?? right.fileURL?.lastPathComponent ?? "Untitled"
        return "\(leftName) ↔ \(rightName)"
    }

    // MARK: - Close-time save prompts
    //
    // Policy: a document gets a save prompt here only if (a) it has unsaved changes, and (b) this
    // compare window is its *only* open window — checked via `document.windowControllers.isEmpty`.
    // If the same document is also open in an ordinary tab, that tab's own window already owns the
    // standard close-prompt behavior for it (and closing just this comparison pane shouldn't
    // discard edits the user can still see and save elsewhere). A solely-owned document that's
    // clean, or that the user chose to save/discard here, is explicitly closed once this window
    // goes away — otherwise it would stay open forever with no window pointing at it, since this
    // window never registered itself as one of `NSDocument`'s window controllers in the first
    // place (see `Document`'s and `ComparePaneViewController`'s documentation for why).

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if confirmedClose { return true }
        attemptClose()
        return false
    }

    private func attemptClose() {
        confirmCloseIfNeeded(for: compareViewController.leftDocument) { [weak self] leftOK in
            guard let self, leftOK else { return }
            self.confirmCloseIfNeeded(for: self.compareViewController.rightDocument) { rightOK in
                guard rightOK else { return }
                self.finishClosing()
            }
        }
    }

    private func finishClosing() {
        closeIfSolelyOwnedAndStillOpen(compareViewController.leftDocument)
        closeIfSolelyOwnedAndStillOpen(compareViewController.rightDocument)
        confirmedClose = true
        window?.close()
        onClosed?()
    }

    private func closeIfSolelyOwnedAndStillOpen(_ document: Document) {
        guard document.windowControllers.isEmpty else { return }
        guard NSDocumentController.shared.documents.contains(where: { $0 === document }) else { return }
        document.close()
    }

    /// Resolves to `true` when it's fine to proceed (nothing to save, or the user resolved it);
    /// `false` on Cancel.
    private func confirmCloseIfNeeded(for document: Document, completion: @escaping (Bool) -> Void) {
        guard document.windowControllers.isEmpty, document.isDocumentEdited else {
            completion(true)
            return
        }
        guard let window else {
            completion(true)
            return
        }

        let name = document.displayName ?? document.fileURL?.lastPathComponent ?? "Untitled"
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \u{201C}\(name)\u{201D}?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: // Save
                guard let url = document.fileURL else {
                    completion(true)
                    return
                }
                document.save(to: url, ofType: document.fileType ?? "com.mded.markdown", for: .saveOperation) { error in
                    if let error {
                        NSAlert(error: error).runModal()
                        completion(false)
                    } else {
                        completion(true)
                    }
                }
            case .alertSecondButtonReturn: // Don't Save
                document.close()
                completion(true)
            default: // Cancel
                completion(false)
            }
        }
    }
}
