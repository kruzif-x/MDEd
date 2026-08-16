import Cocoa
import CryptoKit

/// Owns the document window and its single `EditorViewController`. Native window tabbing is not
/// disabled anywhere here, so it comes free from `NSDocument`/`NSWindow`'s own machinery.
final class DocumentWindowController: NSWindowController {

    private let splitViewController: DocumentSplitViewController
    var editorViewController: EditorViewController { splitViewController.editorViewController }

    init(document: Document) {
        splitViewController = DocumentSplitViewController(document: document)

        let window = MDEdDocumentWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize()),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.mdedDocument = document

        super.init(window: window)

        window.contentViewController = splitViewController
        // Assigning `contentViewController` just above resizes the window to fit
        // `EditorViewController.loadView()`'s own (arbitrary, placeholder) initial view frame,
        // clobbering the `contentRect` passed to `NSWindow(...)` above. Reassert the real default
        // size afterward, then center using that final size.
        window.setContentSize(Self.defaultContentSize())
        window.center()
        // A per-document frame-autosave name/identifier, not one name shared by every document
        // window — previously every window here fought over the single literal string
        // "MDEdDocumentWindow", so opening a second document silently inherited (and then
        // overwrote) the first one's saved size/position instead of getting its own. `Self.token`
        // derives a stable value from the document's file path when it has one, so the *same file*
        // reliably gets back its own remembered frame across launches, while two different files
        // never collide; a document with no path yet (a brand-new "Untitled" window) gets a
        // per-instance random token instead, which is still unique across the windows open in this
        // launch — the property this fix is actually required to guarantee — even though it has no
        // stable meaning across relaunches (nothing to derive it from before the first save).
        //
        // Must be set after `center()`, same as before: `setFrameAutosaveName` immediately applies
        // a previously-saved frame if this token has one on record, and that real saved frame — not
        // the temporary centered one — is what should win.
        let token = Self.autosaveToken(for: document)
        window.setFrameAutosaveName("MDEdDocumentWindow-\(token)")
        // Secure-restorable-state ("Resume") wiring — see `MDEdDocumentWindow` and
        // `DocumentWindowRestoration` for the rest of this mechanism. `identifier` only needs to be
        // a stable per-window key for the duration this state round-trips through a quit/relaunch;
        // reusing the same token as the frame-autosave name is a convenience, not a requirement —
        // the document's identity for restoration purposes is carried in the encoded state itself
        // (the file URL), not decoded from this string.
        window.identifier = NSUserInterfaceItemIdentifier("MDEdDocumentWindow-\(token)")
        window.isRestorable = true
        window.restorationClass = DocumentWindowRestoration.self
        window.minSize = NSSize(width: 480, height: 320)
        window.toolbarStyle = .unified
        window.toolbar = Self.makeToolbar()
        // `synchronizeWindowTitleWithDocumentName` (the NSWindowController default) keeps the
        // title, proxy icon, and edited-dot in sync with the document automatically.
    }

    /// A stable token for `document`'s current file path (SHA-256 hex, so any path's arbitrary
    /// characters are always a safe, fixed-length autosave-name/identifier suffix), or a fresh
    /// random one for a document with no path yet. See the call site above for why either is
    /// exactly what's needed there.
    private static func autosaveToken(for document: Document) -> String {
        guard let path = document.fileURL?.path else { return UUID().uuidString }
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — this app has no storyboard/xib")
    }

    // MARK: - Sizing

    /// A comfortable first-launch window size: wide enough that the default measure (columns) has
    /// real margin on both sides rather than sitting hard against `EditorViewController`'s
    /// `minimumMargin`, so the layout doesn't read as cramped before the user manually resizes.
    /// Only used for the very first launch — `setFrameAutosaveName` above restores whatever the
    /// user last left the window at on every subsequent one.
    ///
    /// Adds the outline sidebar's default width when it starts out visible (the factory default —
    /// see `EditorSettings.default.showOutlineSidebar`), so a brand-new install's first window
    /// isn't quietly cramping the editor's own measure by however much the sidebar takes: the
    /// sidebar is *extra* width, not width borrowed from the editor's comfortable margin.
    private static func defaultContentSize() -> NSSize {
        let settings = EditorSettings.default
        let font = MarkdownStyler.baseFont(settings)
        let measureWidth = settings.measureWidthPoints(font: font)
        let comfortableMargin: CGFloat = 160 // beyond EditorViewController.minimumMargin per side
        let editorWidth = measureWidth + 2 * (EditorViewController.minimumMargin + comfortableMargin)
        let sidebarAllowance: CGFloat = settings.showOutlineSidebar ? DocumentSplitViewController.defaultSidebarWidth : 0
        return NSSize(width: max(editorWidth, 920) + sidebarAllowance, height: 900)
    }

    // MARK: - Toolbar

    /// A restrained, user-customizable toolbar. Every item earns its slot by doing something a
    /// menu-only action wouldn't: Cut/Copy/Paste are the everyday clipboard trio made one click
    /// away instead of only a keyboard shortcut, and the four formatting buttons are the
    /// bread-and-butter Markdown marker insertions (wrap-selection-in-`**`/`*`/`` ` ``, and a link
    /// skeleton) — genuinely useful in a *styled source* editor where those markers are exactly
    /// what the user is typing by hand, and a one-click "wrap" beats reaching for the keyboard for
    /// two characters at each end of a selection. Settings sits at the trailing edge because this
    /// whole pass is about making the editor's look configurable — surfacing it in the toolbar,
    /// not just behind ⌘,, makes that discoverable. `.toggleSidebar` and `.sidebarTrackingSeparator`
    /// are both AppKit's own standard, self-vending toolbar identifiers — including them is enough;
    /// `itemForItemIdentifier` below never needs a case for either, the same way it never needed one
    /// for `.space`/`.flexibleSpace`. Deliberately excluded: New/Open/Save (already fast via
    /// ⌘N/⌘O/⌘S and add nothing a toolbar button says better) and a preview toggle (out of scope —
    /// no rendered view exists).
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
    static let cut = NSToolbarItem.Identifier("com.mded.toolbar.cut")
    static let copy = NSToolbarItem.Identifier("com.mded.toolbar.copy")
    static let paste = NSToolbarItem.Identifier("com.mded.toolbar.paste")
    static let bold = NSToolbarItem.Identifier("com.mded.toolbar.bold")
    static let italic = NSToolbarItem.Identifier("com.mded.toolbar.italic")
    static let inlineCode = NSToolbarItem.Identifier("com.mded.toolbar.inlineCode")
    static let link = NSToolbarItem.Identifier("com.mded.toolbar.link")
    static let addNote = NSToolbarItem.Identifier("com.mded.toolbar.addNote")
    static let notesList = NSToolbarItem.Identifier("com.mded.toolbar.notesList")
    static let settings = NSToolbarItem.Identifier("com.mded.toolbar.settings")
}

/// A plain `NSObject` (not the window controller itself) so the toolbar's weak delegate reference
/// doesn't need to keep a whole `DocumentWindowController` alive, and so the same delegate
/// instance can be shared across every document window.
private final class ToolbarDelegate: NSObject, NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .cut, .copy, .paste, .space, .bold, .italic, .inlineCode, .link, .addNote, .flexibleSpace, .settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .cut, .copy, .paste, .bold, .italic, .inlineCode, .link, .addNote, .notesList, .settings, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .cut:
            // `target = nil`, action = the standard `NSText` selector: routes through the
            // responder chain to whichever `NSTextView` is first responder, exactly like the Edit
            // menu's own Cut item (`AppDelegate.editMenu()`) already does. `NSToolbarItem`
            // auto-validates the same way `NSMenuItem` does — by walking the responder chain to
            // find the target and, if it conforms to `NSUserInterfaceValidations`, asking it via
            // `validateUserInterfaceItem:` — and `NSTextView` already implements that for
            // cut:/copy:/paste: (it's exactly how the existing Edit menu items grey out over an
            // empty selection or an empty pasteboard). No custom validation code needed here.
            return nilTargetItem(.cut, label: "Cut", symbol: "scissors", tooltip: "Cut the selection", action: #selector(NSText.cut(_:)))
        case .copy:
            return nilTargetItem(.copy, label: "Copy", symbol: "doc.on.doc", tooltip: "Copy the selection", action: #selector(NSText.copy(_:)))
        case .paste:
            return nilTargetItem(.paste, label: "Paste", symbol: "doc.on.clipboard", tooltip: "Paste", action: #selector(NSText.paste(_:)))
        case .bold:
            // `target = nil`: these route through the responder chain to whichever
            // `EditorViewController` is the key window's content view controller, so the same
            // toolbar item works correctly no matter which document window it's clicked in.
            return nilTargetItem(.bold, label: "Bold", symbol: "bold", tooltip: "Wrap the selection in ** bold ** markers", action: #selector(EditorViewController.toolbarInsertBold(_:)))
        case .italic:
            return nilTargetItem(.italic, label: "Italic", symbol: "italic", tooltip: "Wrap the selection in * italic * markers", action: #selector(EditorViewController.toolbarInsertItalic(_:)))
        case .inlineCode:
            return nilTargetItem(.inlineCode, label: "Code", symbol: "chevron.left.forwardslash.chevron.right", tooltip: "Wrap the selection in `inline code` markers", action: #selector(EditorViewController.toolbarInsertInlineCode(_:)))
        case .link:
            return nilTargetItem(.link, label: "Link", symbol: "link", tooltip: "Wrap the selection as a [link](url)", action: #selector(EditorViewController.toolbarInsertLink(_:)))
        case .addNote:
            return nilTargetItem(.addNote, label: "Add Note", symbol: "note.text", tooltip: "Add a review note to the selection (⌥⌘N)", action: #selector(EditorViewController.addNote(_:)))
        case .notesList:
            return nilTargetItem(.notesList, label: "Notes", symbol: "list.bullet.rectangle", tooltip: "Show all review notes", action: #selector(EditorViewController.showAllNotes(_:)))
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

    private func nilTargetItem(_ identifier: NSToolbarItem.Identifier, label: String, symbol: String, tooltip: String, action: Selector) -> NSToolbarItem {
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
