import Cocoa
import MDEdCore

/// A read-only window that displays one of the app's bundled Markdown documents (Help ▸ MDEd
/// Help, Help ▸ Acknowledgements) — styled by the app's *own* `MarkdownTextView` +
/// `MarkdownStyler` stack, so the help looks exactly like a document in the editor and every
/// improvement to the styler (fonts, themes, code-block backgrounds) reaches it for free.
///
/// Unlike the editor, this stack is standalone: there is no `NSDocument` behind it, so the
/// content storage, text storage, and layout manager are built here directly — the same
/// `Document.makeTextContainer()` shape (content storage → attached layout manager →
/// container, with a `TextLayoutAttachment` held for exactly this controller's lifetime so
/// the detach happens automatically), minus the document. Nothing here is editable, there's
/// no gutter, no live preview, and no undo, which keeps it a few dozen lines of plumbing.
final class HelpDocumentWindowController: NSWindowController {

    /// The fixed comfortable column the help text is centered in — same role as the editor's
    /// configurable measure, just not user-configurable: help has one author, not many.
    static let measureWidth: CGFloat = 620

    private let hostingController: HelpHostingController

    /// Builds the window for `markdown` titled `title`.
    init(title: String, markdown: String) {
        hostingController = HelpHostingController(markdown: markdown)

        let window = NSWindow(contentViewController: hostingController)
        // A help window is a reference surface, not a document — the standard size just needs
        // to be comfortable, and the user's preferred size should persist per window kind.
        window.setContentSize(NSSize(width: 760, height: 820))
        window.center()
        window.setFrameAutosaveName("MDEdHelpWindow-\(title)")
        window.title = title
        window.minSize = NSSize(width: 420, height: 300)

        super.init(window: window)
        // Cached and reused by its owner (`AppDelegate`) across shows, like the Settings
        // panel — closing must not deallocate the controller out from under that cache.
        window.isReleasedWhenClosed = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — this app has no storyboard/xib")
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Owns the scroll view and read-only `MarkdownTextView`, and applies the same
/// settings-derived styling the editor does — font, theme via system colors, block
/// decorations — refreshed live when Settings changes, the same way every open editor
/// refreshes. `EditorViewController.horizontalInset` is reused verbatim for the centered
/// measure so the help column and editor columns center by identical math.
private final class HelpHostingController: NSViewController {

    /// The fixed column width in points — see `HelpDocumentWindowController.measureWidth`.
    private static let measureWidth = HelpDocumentWindowController.measureWidth

    private let scrollView = NSScrollView()
    private let textView: MarkdownTextView
    /// Keeps the help's layout manager attached to its (standalone) content storage for
    /// exactly this view controller's lifetime — see `TextLayoutAttachment`'s doc comment.
    private let layoutAttachment: TextLayoutAttachment
    private var settingsObserver: NSObjectProtocol?
    private var lastAppliedSettings: EditorSettings?
    private var lastMeasure: CGFloat = -1

    init(markdown: String) {
        // Standalone TextKit 2 stack — see this file's top-level doc comment for why it's
        // shaped exactly like `Document.makeTextContainer()` minus the document.
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = NSTextStorage(string: markdown)
        let attachment = TextLayoutAttachment(attachingTo: contentStorage)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        attachment.layoutManager.textContainer = container

        layoutAttachment = attachment
        textView = MarkdownTextView(frame: .zero, textContainer: container)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — this app has no storyboard/xib")
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 820))

        let settings = EditorSettings.current()
        textView.font = MarkdownStyler.baseFont(settings)
        textView.isEditable = false
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        // Same nonzero value and for the same reason as the editor's — see
        // `EditorViewController.lineFragmentPadding`'s doc comment for the TextKit 2 crash a
        // zero value invites.
        textView.textContainer?.lineFragmentPadding = 1
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 32, height: 24)
        textView.setAccessibilityLabel("Help document")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applySettingsIfNeeded()
        }
        applySettingsIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateMeasure()
    }

    /// Font/spacing changes restyle in place; same `lastAppliedSettings` guard discipline as
    /// `EditorViewController.applyCurrentSettings()` — `UserDefaults.didChangeNotification`
    /// fires for any write to the domain by any framework (WebKit's first web process does
    /// exactly that), and there's no reason to restyle the help for it.
    private func applySettingsIfNeeded() {
        let settings = EditorSettings.current()
        guard settings != lastAppliedSettings else { return }
        lastAppliedSettings = settings
        textView.font = MarkdownStyler.baseFont(settings)
        restyle()
        updateMeasure()
    }

    private func updateMeasure() {
        let available = textView.bounds.width
        guard available > 1 else { return }
        guard abs(available - lastMeasure) > 0.05 else { return }
        lastMeasure = available
        textView.textContainerInset = NSSize(
            width: EditorViewController.horizontalInset(available: available, measure: Self.measureWidth),
            height: textView.textContainerInset.height
        )
    }

    private func restyle() {
        guard let textStorage = textView.textStorage else { return }
        let settings = EditorSettings.current()
        withoutRegisteringUndo(on: textView.undoManager) {
            let decorations = MarkdownStyler.restyle(textStorage, settings: settings)
            textView.blockDecorations = decorations
        }
    }
}
