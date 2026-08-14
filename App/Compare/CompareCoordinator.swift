import Cocoa
import UniformTypeIdentifiers

/// Presents the comparison window's two entry points (see `AppDelegate`'s File menu) and owns the
/// resulting `CompareWindowController`s for as long as their windows are open — nothing else holds
/// a strong reference to one, so without this they'd be deallocated (and their window closed out
/// from under the user) the instant the presenting method returns.
enum CompareCoordinator {

    private static var activeWindowControllers: [CompareWindowController] = []

    /// File ▸ Compare Two Files… — asks for two arbitrary files and compares them.
    static func presentCompareTwoFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.text]
        panel.message = "Choose two files to compare."
        panel.prompt = "Compare"

        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            guard urls.count == 2 else {
                presentError(message: "Select exactly two files to compare.")
                return
            }
            openBoth(urls[0], urls[1])
        }
    }

    /// File ▸ Compare Frontmost With… — compares the key window's document against a chosen file.
    static func presentCompareFrontmostDocument() {
        guard let current = NSDocumentController.shared.currentDocument as? Document else {
            presentError(message: "Open a document first, then choose “Compare Frontmost With…”.")
            return
        }
        guard current.fileURL != nil else {
            presentError(message: "Save this document before comparing it against another file.")
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.text]
        panel.message = "Choose a file to compare against “\(current.displayName ?? "the current document")”."
        panel.prompt = "Compare"

        panel.begin { response in
            guard response == .OK, let url = panel.urls.first else { return }
            openSecond(url, against: current)
        }
    }

    // MARK: - Opening documents

    private static func openBoth(_ urlA: URL, _ urlB: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: urlA, display: false) { docA, _, errorA in
            if let errorA {
                presentError(error: errorA)
                return
            }
            guard let left = docA as? Document else { return }
            NSDocumentController.shared.openDocument(withContentsOf: urlB, display: false) { docB, _, errorB in
                if let errorB {
                    presentError(error: errorB)
                    return
                }
                guard let right = docB as? Document else { return }
                present(left: left, right: right)
            }
        }
    }

    private static func openSecond(_ url: URL, against left: Document) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { docB, _, error in
            if let error {
                presentError(error: error)
                return
            }
            guard let right = docB as? Document else { return }
            present(left: left, right: right)
        }
    }

    private static func present(left: Document, right: Document) {
        let controller = CompareWindowController(leftDocument: left, rightDocument: right)
        controller.onClosed = {
            activeWindowControllers.removeAll { $0 === controller }
        }
        activeWindowControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Errors

    private static func presentError(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func presentError(error: Error) {
        NSAlert(error: error).runModal()
    }
}
