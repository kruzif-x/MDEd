import Cocoa
import MDEdCore

/// One side (left or right) of the comparison window: a single `MarkdownTextView` attached to a
/// `Document`'s shared text storage, styled the same way an ordinary editor tab is, plus whatever
/// diff decoration `CompareViewController` (its owner) hands it.
///
/// This is deliberately not a subclass of `EditorViewController` — it has no status bar, no
/// toolbar formatting actions, and its restyle pass is orchestrated externally (see
/// `restyleNow()`) rather than on its own debounce timer, because `CompareViewController` needs to
/// restyle *and* re-decorate both panes together, atomically, on one timer; two independently
/// debounced panes could each wipe the other's freshly applied diff decoration mid-flicker.
final class ComparePaneViewController: NSViewController {

    /// Fixed margin, mirroring `EditorViewController.minimumMargin` — the comparison window
    /// prioritizes seeing both documents at once over the single-document measure/centering
    /// treatment, so this stays a plain constant rather than reimplementing that logic.
    private static let horizontalInset: CGFloat = 20
    private static let verticalInset: CGFloat = 20

    /// See `EditorViewController.lineFragmentPadding` — must be nonzero, or opening a short
    /// document (one that fits entirely within one viewport) whose first character is `#`, `-`,
    /// or `*` throws the `NSTextContentStorage locationFromLocation:withOffset:` exception this
    /// app was chasing. Unlike the editor tab, this pane has no column-exact measure to protect,
    /// so the couple of points this costs the usable width just isn't worth compensating for.
    private static let lineFragmentPadding: CGFloat = 1

    let document: Document
    let scrollView = NSScrollView()
    let textView: MarkdownTextView
    private var lineNumberGutter: LineNumberGutterView?

    /// Owns detaching `textView`'s layout manager from `document`'s shared content storage — see
    /// `TextLayoutAttachment`'s doc comment and `EditorViewController.layoutAttachment` (this
    /// type's mirror of it).
    private let layoutAttachment: TextLayoutAttachment

    /// Fired on every actual edit (not on programmatic attribute-only changes) so the owner can
    /// debounce a diff recompute across both panes.
    var onTextChanged: (() -> Void)?

    var currentText: String { textView.string }

    init(document: Document) {
        self.document = document
        let (container, attachment) = document.makeTextContainer()
        layoutAttachment = attachment
        textView = MarkdownTextView(frame: .zero, textContainer: container)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — this app has no storyboard/xib")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 600))
        configureTextView()
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureTextView() {
        let settings = EditorSettings.current()
        textView.font = MarkdownStyler.baseFont(settings)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: Self.horizontalInset, height: Self.verticalInset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = Self.lineFragmentPadding
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        configureLineNumberGutter()
    }

    /// See `EditorViewController.configureLineNumberGutter()` — same reasoning, same "always
    /// attached, visibility flips" shape. This pane's numbering is its own document's, independent
    /// of whatever the other pane shows — line numbers are arguably more useful here than in the
    /// single-document editor, since they're one of the few common reference points between two
    /// documents that otherwise differ line-for-line.
    private func configureLineNumberGutter() {
        let gutter = LineNumberGutterView(textView: textView, scrollView: scrollView)
        lineNumberGutter = gutter
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = EditorSettings.current().showLineNumbers
    }

    /// Toggles this pane's gutter live — called by `CompareViewController` when the Settings line-
    /// number toggle changes, mirroring how `EditorViewController.applyCurrentSettings()` does the
    /// same for a single editor tab.
    func setLineNumbersVisible(_ visible: Bool) {
        scrollView.rulersVisible = visible
        scrollView.tile()
        lineNumberGutter?.updateThickness()
    }

    // MARK: - Styling (orchestrated by CompareViewController)

    /// Reapplies markdown styling from scratch — attributes only, wrapped in the text storage's
    /// own `beginEditing()`/`endEditing()` by `MarkdownStyler.restyle` — and returns the block
    /// decorations the caller should set on `textView.blockDecorations`. Diff decorations are a
    /// separate, later pass (see `CompareViewController`) since they depend on both panes' text at
    /// once, which this method has no view of.
    @discardableResult
    func restyleNow() -> [BlockDecoration] {
        guard let textStorage = textView.textStorage else { return [] }
        let decorations = MarkdownStyler.restyle(textStorage, settings: EditorSettings.current())
        textView.blockDecorations = decorations
        resetTypingAttributes()
        lineNumberGutter?.updateThickness()
        lineNumberGutter?.needsDisplay = true
        return decorations
    }

    func finishInitialSetup() {
        restyleNow()
    }

    private func resetTypingAttributes() {
        textView.typingAttributes = [
            .font: MarkdownStyler.baseFont(EditorSettings.current()),
            .foregroundColor: NSColor.labelColor,
        ]
    }

    // MARK: - Scroll position

    var verticalOffset: CGFloat {
        get { scrollView.contentView.bounds.origin.y }
        set {
            let clip = scrollView.contentView
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            var origin = clip.bounds.origin
            origin.y = min(max(newValue, 0), maxY)
            clip.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// Scrolls so `lineRange` (source-line indices, per `DocumentLines`) is visible, and selects
    /// it — the visible "jump to this change" affordance for hunk navigation.
    func scrollToAndSelect(lineRange: Range<Int>, in lines: DocumentLines) {
        guard !lineRange.isEmpty, lineRange.upperBound <= lines.count else { return }
        let start = lines.lineRanges[lineRange.lowerBound].lowerBound
        let end = lines.lineRanges[lineRange.upperBound - 1].upperBound
        let range = NSRange(location: start, length: max(0, end - start))
        textView.scrollRangeToVisible(range)
        textView.setSelectedRange(range)
    }

    /// The source-line index (per `lines`) whose layout fragment is at (or nearest below) the top
    /// of the currently visible area — used to figure out "the change nearest where the user is
    /// looking" for hunk navigation.
    func topVisibleLineIndex(in lines: DocumentLines) -> Int? {
        guard let tlm = textView.textLayoutManager, let cm = tlm.textContentManager else { return nil }
        let point = NSPoint(x: 1, y: scrollView.contentView.bounds.origin.y + 1)
        guard let fragment = tlm.textLayoutFragment(for: point) else { return nil }
        let docLocation = cm.documentRange.location
        let offset = cm.offset(from: docLocation, to: fragment.rangeInElement.location)
        guard offset >= 0 else { return nil }
        return lines.lineIndex(atUTF16Offset: offset)
    }

    /// The rendered height, in points, of each source line (per `lines`) in this pane — the
    /// per-pane input `ScrollOffsetMapper` needs, since wrapping (and so a line's true height)
    /// depends on this pane's own container width and font, not the diff itself.
    ///
    /// TextKit 2 lays out one `NSTextLayoutFragment` per paragraph, which — since paragraphs are
    /// split on the same `"\n"` `DocumentLines` splits on — should align 1:1 with `lines.count`.
    /// If it doesn't (an edge case in an empty or pathological document), the array is padded or
    /// truncated to match rather than letting a caller index out of bounds.
    func measuredLineHeights(matching lines: DocumentLines) -> [Double] {
        guard let tlm = textView.textLayoutManager, let cm = tlm.textContentManager else {
            return Array(repeating: fallbackLineHeight, count: lines.count)
        }
        var heights: [Double] = []
        tlm.enumerateTextLayoutFragments(from: cm.documentRange.location, options: [.ensuresLayout]) { fragment in
            heights.append(Double(fragment.layoutFragmentFrame.height))
            return true
        }
        if heights.count < lines.count {
            heights.append(contentsOf: Array(repeating: fallbackLineHeight, count: lines.count - heights.count))
        } else if heights.count > lines.count {
            heights = Array(heights.prefix(lines.count))
        }
        return heights
    }

    private var fallbackLineHeight: Double {
        let font = textView.font ?? MarkdownStyler.baseFont(EditorSettings.current())
        return Double(font.ascender - font.descender + font.leading)
    }
}

// MARK: - NSTextViewDelegate

extension ComparePaneViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        onTextChanged?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        resetTypingAttributes()
    }

    /// Routes undo through the document's own undo manager instead of the responder chain (which
    /// would normally source it from `self.window?.windowController?.document` — but this pane's
    /// window has no single `.document`, since it hosts two). Returning `document.undoManager`
    /// directly gives this pane a real, document-owned undo stack — the *same* one an ordinary
    /// editor tab on this document uses, if one is also open — and `NSDocument`'s own dirty-flag
    /// tracking (which observes its undo manager's notifications, not any particular window) keeps
    /// working automatically as a result. See `Document`'s documentation for why sharing goes all
    /// the way down to a single text storage in the first place.
    func undoManager(for view: NSTextView) -> UndoManager? {
        document.undoManager
    }
}
