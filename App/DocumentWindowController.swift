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
        window.toolbarStyle = .unified
        window.toolbar = Self.makeToolbar()
        // `synchronizeWindowTitleWithDocumentName` (the NSWindowController default) keeps the
        // title, proxy icon, and edited-dot in sync with the document automatically.
    }

    // MARK: - Toolbar

    /// A restrained, user-customizable toolbar. Every item earns its slot by doing something a
    /// menu-only action wouldn't: the four formatting buttons are the bread-and-butter Markdown
    /// marker insertions (wrap-selection-in-`**`/`*`/`` ` ``, and a link skeleton) — genuinely
    /// useful in a *styled source* editor where those markers are exactly what the user is typing
    /// by hand, and a one-click "wrap" beats reaching for the keyboard for two characters at each
    /// end of a selection. Settings sits at the trailing edge because this whole pass is about
    /// making the editor's look configurable — surfacing it in the toolbar, not just behind ⌘,,
    /// makes that discoverable. Deliberately excluded: New/Open/Save (already fast via ⌘N/⌘O/⌘S
    /// and add nothing a toolbar button says better), a preview toggle (out of scope — no
    /// rendered view exists), and a sidebar toggle (no sidebar exists).
    private static func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "MDEdMainToolbar")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        return toolbar
    }

    /// Kept alive for the process lifetime as the toolbar's delegate (`NSToolbar.delegate` is
    /// weak).
    private static let toolbarDelegate = ToolbarDelegate()
}

// MARK: - NSToolbarDelegate

private extension NSToolbarItem.Identifier {
    static let bold = NSToolbarItem.Identifier("com.mded.toolbar.bold")
    static let italic = NSToolbarItem.Identifier("com.mded.toolbar.italic")
    static let inlineCode = NSToolbarItem.Identifier("com.mded.toolbar.inlineCode")
    static let link = NSToolbarItem.Identifier("com.mded.toolbar.link")
    static let settings = NSToolbarItem.Identifier("com.mded.toolbar.settings")
}

/// A plain `NSObject` (not the window controller itself) so the toolbar's weak delegate reference
/// doesn't need to keep a whole `DocumentWindowController` alive, and so the same delegate
/// instance can be shared across every document window.
private final class ToolbarDelegate: NSObject, NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.bold, .italic, .inlineCode, .link, .flexibleSpace, .settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.bold, .italic, .inlineCode, .link, .settings, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .bold:
            // `target = nil`: these route through the responder chain to whichever
            // `EditorViewController` is the key window's content view controller, so the same
            // toolbar item works correctly no matter which document window it's clicked in.
            return formattingItem(.bold, label: "Bold", symbol: "bold", tooltip: "Wrap the selection in ** bold ** markers", action: #selector(EditorViewController.toolbarInsertBold(_:)))
        case .italic:
            return formattingItem(.italic, label: "Italic", symbol: "italic", tooltip: "Wrap the selection in * italic * markers", action: #selector(EditorViewController.toolbarInsertItalic(_:)))
        case .inlineCode:
            return formattingItem(.inlineCode, label: "Code", symbol: "chevron.left.forwardslash.chevron.right", tooltip: "Wrap the selection in `inline code` markers", action: #selector(EditorViewController.toolbarInsertInlineCode(_:)))
        case .link:
            return formattingItem(.link, label: "Link", symbol: "link", tooltip: "Wrap the selection as a [link](url)", action: #selector(EditorViewController.toolbarInsertLink(_:)))
        case .settings:
            let item = NSToolbarItem(itemIdentifier: .settings)
            item.label = "Settings"
            item.paletteLabel = "Settings"
            item.toolTip = "Open Settings (⌘,)"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            item.target = NSApp.delegate as AnyObject?
            item.action = #selector(AppDelegate.showSettings(_:))
            item.isBordered = true
            return item
        default:
            return nil
        }
    }

    private func formattingItem(_ identifier: NSToolbarItem.Identifier, label: String, symbol: String, tooltip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tooltip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = nil
        item.action = action
        item.isBordered = true
        return item
    }
}
