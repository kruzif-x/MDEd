import Cocoa
import MDEdCore

/// Hosts the single `NSTextView` editor plus an unobtrusive status bar. Plain AppKit throughout —
/// no `NSViewRepresentable`, per the project's architecture notes.
final class EditorViewController: NSViewController {

    /// How long to wait after the last keystroke before re-parsing and restyling. Long enough that
    /// fast typing doesn't reparse on every character, short enough that styling feels immediate.
    private static let restyleDebounce: TimeInterval = 0.12

    /// Fixed vertical breathing room so the first line isn't jammed under the title bar and the
    /// last line can scroll clear of the bottom. Not user-configurable — unlike the horizontal
    /// margin, this doesn't need to react to window width, just to feel generous.
    private static let verticalPadding: CGFloat = 32

    /// The smallest horizontal margin the measure ever shrinks to, even in a narrow window.
    private static let minimumMargin: CGFloat = 32

    private let scrollView = NSScrollView()
    private let textView: MarkdownTextView
    private let statusDivider = NSBox()
    private let statusBar = NSVisualEffectView()
    private let statusLabel = NSTextField(labelWithString: "")

    private var restyleWorkItem: DispatchWorkItem?
    private var isApplyingInitialText = false
    private var settingsObserver: NSObjectProtocol?
    private var lastAppliedMeasureWidth: CGFloat = -1
    private var lastKnownAvailableWidth: CGFloat = -1
    /// The word-count/reading-time portion of the status line, cached so a caret move (which
    /// happens far more often than a text edit) doesn't have to re-run `WordCount.analyze`.
    private var cachedWordCountText: String = ""

    var currentText: String { textView.string }

    init() {
        // Explicit TextKit 2 opt-in (the default on this SDK, but explicit beats implicit for a
        // choice this load-bearing to the whole styling approach).
        textView = MarkdownTextView(usingTextLayoutManager: true)
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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 720))
        configureTextView()
        configureStatusBar()
        configureLayout()
        observeSettingsChanges()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateMeasure()
    }

    // MARK: - Configuration

    private func configureTextView() {
        // A *styled source* view (markers like "##"/"**" stay visible), closer in spirit to a code
        // editor with syntax highlighting than to a prose WYSIWYG surface. Font family is user
        // configurable (Settings, ⌘,): monospaced keeps ATX markers, list bullets, blockquote
        // bars, and fenced code aligned and predictable; proportional reads better for prose. See
        // `MarkdownStyler` for how emphasis styling adapts to whichever is active.
        let settings = EditorSettings.current()
        textView.font = MarkdownStyler.baseFont(settings)
        textView.isRichText = false
        textView.allowsUndo = true
        // `MarkdownTextView.draw(_:)` paints the base fill itself so block-background decorations
        // land behind glyphs instead of being erased by NSTextView's own opaque background wash —
        // see that class's doc comment. `backgroundColor` still needs a real value since our draw
        // override reads it.
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: Self.minimumMargin, height: Self.verticalPadding)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // The native find bar (⌘F), driven by the Find menu built in AppDelegate.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
    }

    private func configureStatusBar() {
        statusBar.material = .headerView
        statusBar.blendingMode = .withinWindow
        statusBar.state = .active

        statusDivider.boxType = .separator

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
    }

    private func configureLayout() {
        for subview in [scrollView, statusBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        statusBar.addSubview(statusDivider)
        statusBar.addSubview(statusLabel)
        statusDivider.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 22),

            statusDivider.topAnchor.constraint(equalTo: statusBar.topAnchor),
            statusDivider.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            statusDivider.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),

            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
        ])
    }

    // MARK: - Content

    func setInitialText(_ text: String) {
        isApplyingInitialText = true
        textView.string = text
        isApplyingInitialText = false
        restyleNow()
        updateStatusNow()
    }

    // MARK: - Measure (constrained, centered text column)

    /// Caps the text container at `EditorSettings.measureWidth` and centers it by growing
    /// `textContainerInset`'s horizontal component — a wider window becomes more margin, not a
    /// longer line. Below `measureWidth + 2 * minimumMargin` the margin shrinks down to
    /// `minimumMargin` and the line itself narrows, which is the graceful behavior for a small
    /// window rather than clipping or forcing a horizontal scrollbar.
    private func updateMeasure() {
        let available = scrollView.contentView.bounds.width
        guard available > 1, available != lastKnownAvailableWidth || lastAppliedMeasureWidth < 0 else { return }
        lastKnownAvailableWidth = available

        let measure = CGFloat(EditorSettings.current().measureWidth)
        guard measure != lastAppliedMeasureWidth || abs(available - lastKnownAvailableWidth) > 0.5 else { return }
        lastAppliedMeasureWidth = measure

        let horizontalInset = max(Self.minimumMargin, (available - measure) / 2)
        var inset = textView.textContainerInset
        inset.width = horizontalInset
        textView.textContainerInset = inset
    }

    // MARK: - Settings (live)

    private func observeSettingsChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyCurrentSettings()
        }
    }

    /// Reapplies every settings-derived property to the *already open* document — font, measure,
    /// spacing, restyle (which also reapplies the new font/spacing to every existing construct).
    /// This is what makes a Settings change visible immediately instead of only affecting new
    /// windows.
    private func applyCurrentSettings() {
        let settings = EditorSettings.current()
        textView.font = MarkdownStyler.baseFont(settings)
        resetTypingAttributes()
        // Force the measure to recompute even if the window didn't resize.
        lastAppliedMeasureWidth = -1
        updateMeasure()
        restyleNow()
        textView.needsDisplay = true
    }

    // MARK: - Debounced restyle + status

    private func scheduleRestyleAndStatus() {
        restyleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.restyleNow()
            self?.updateStatusNow()
        }
        restyleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restyleDebounce, execute: work)
    }

    private func restyleNow() {
        guard let textStorage = textView.textStorage else { return }
        let settings = EditorSettings.current()
        let decorations = MarkdownStyler.restyle(textStorage, settings: settings)
        textView.blockDecorations = decorations
        resetTypingAttributes()
    }

    private func updateStatusNow() {
        let result = WordCount.analyze(textView.string)
        let words = result.wordCount == 1 ? "1 word" : "\(result.wordCount) words"
        cachedWordCountText = "\(words) · \(result.readingTime)"
        updateCursorPositionOnly()
    }

    /// Cheaper than a full `updateStatusNow()` — recomputing word count on every arrow-key press
    /// or click would be wasteful when only the caret moved.
    private func updateCursorPositionOnly() {
        let (line, column) = lineAndColumn(at: textView.selectedRange().location)
        statusLabel.stringValue = "\(cachedWordCountText) · Ln \(line), Col \(column)"
    }

    private func lineAndColumn(at location: Int) -> (line: Int, column: Int) {
        let ns = textView.string as NSString
        let clamped = min(max(location, 0), ns.length)
        var line = 1
        var lastLineStart = 0
        var searchStart = 0
        while searchStart < clamped {
            let found = ns.range(of: "\n", range: NSRange(location: searchStart, length: clamped - searchStart))
            guard found.location != NSNotFound else { break }
            line += 1
            lastLineStart = found.location + 1
            searchStart = found.location + 1
        }
        return (line, clamped - lastLineStart + 1)
    }

    /// Keeps text typed at a caret from silently inheriting whatever attributes (bold, italic,
    /// dimmed marker color, …) happen to sit at that boundary — e.g. right after the closing `**`
    /// of a bold run. Called after every restyle pass and on every selection change, so the typing
    /// attributes are always the plain baseline; the next debounced restyle re-derives real
    /// styling for whatever the user actually typed.
    private func resetTypingAttributes() {
        textView.typingAttributes = [
            .font: MarkdownStyler.baseFont(EditorSettings.current()),
            .foregroundColor: NSColor.labelColor,
        ]
    }

    // MARK: - Toolbar-driven formatting

    /// Wraps the selection in `marker` on both sides (`**word**`, `*word*`, `` `word` ``). With no
    /// selection, inserts a placeholder between the markers and selects it, so typing immediately
    /// replaces it — the same affordance every Markdown editor's toolbar buttons offer.
    private func wrapSelection(with marker: String, placeholder: String = "text") {
        let selected = textView.selectedRange()
        let ns = textView.string as NSString
        let hasSelection = selected.length > 0
        let word = hasSelection ? ns.substring(with: selected) : placeholder
        let replacement = "\(marker)\(word)\(marker)"

        textView.insertText(replacement, replacementRange: selected)
        let innerRange = NSRange(location: selected.location + (marker as NSString).length, length: (word as NSString).length)
        textView.setSelectedRange(innerRange)
        scheduleRestyleAndStatus()
    }

    @objc func toolbarInsertBold(_ sender: Any?) {
        wrapSelection(with: "**")
    }

    @objc func toolbarInsertItalic(_ sender: Any?) {
        wrapSelection(with: "*")
    }

    @objc func toolbarInsertInlineCode(_ sender: Any?) {
        wrapSelection(with: "`", placeholder: "code")
    }

    @objc func toolbarInsertLink(_ sender: Any?) {
        let selected = textView.selectedRange()
        let ns = textView.string as NSString
        let text = selected.length > 0 ? ns.substring(with: selected) : "link text"
        let replacement = "[\(text)](url)"

        textView.insertText(replacement, replacementRange: selected)
        let urlPlaceholderStart = selected.location + (("[" + text + "](") as NSString).length
        textView.setSelectedRange(NSRange(location: urlPlaceholderStart, length: 3))
        scheduleRestyleAndStatus()
    }
}

// MARK: - NSTextViewDelegate

extension EditorViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard !isApplyingInitialText else { return }
        scheduleRestyleAndStatus()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        resetTypingAttributes()
        updateCursorPositionOnly()
    }
}
