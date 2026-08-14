import Cocoa
import MDEdCore

/// Hosts the single `NSTextView` editor plus an unobtrusive status bar. Plain AppKit throughout —
/// no `NSViewRepresentable`, per the project's architecture notes.
final class EditorViewController: NSViewController {

    /// How long to wait after the last keystroke before re-parsing and restyling. Long enough that
    /// fast typing doesn't reparse on every character, short enough that styling feels immediate.
    private static let restyleDebounce: TimeInterval = 0.12

    private let scrollView = NSScrollView()
    private let textView: NSTextView
    private let statusDivider = NSBox()
    private let statusBar = NSVisualEffectView()
    private let statusLabel = NSTextField(labelWithString: "")

    private var restyleWorkItem: DispatchWorkItem?
    private var isApplyingInitialText = false

    var currentText: String { textView.string }

    init() {
        // Explicit TextKit 2 opt-in (the default on this SDK, but explicit beats implicit for a
        // choice this load-bearing to the whole styling approach).
        textView = NSTextView(usingTextLayoutManager: true)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — this app has no storyboard/xib")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 720))
        configureTextView()
        configureStatusBar()
        configureLayout()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
    }

    // MARK: - Configuration

    private func configureTextView() {
        // Monospaced, deliberately: this is a *styled source* view (markers like "##"/"**" stay
        // visible), closer in spirit to a code editor with syntax highlighting than to a prose
        // WYSIWYG surface. A monospaced face keeps ATX markers, list bullets, blockquote bars, and
        // fenced code aligned and predictable, which a proportional face would undercut.
        textView.font = MarkdownStyler.baseFont()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
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
        MarkdownStyler.restyle(textStorage)
        resetTypingAttributes()
    }

    private func updateStatusNow() {
        let result = WordCount.analyze(textView.string)
        let words = result.wordCount == 1 ? "1 word" : "\(result.wordCount) words"
        statusLabel.stringValue = "\(words) · \(result.readingTime)"
    }

    /// Keeps text typed at a caret from silently inheriting whatever attributes (bold, italic,
    /// dimmed marker color, …) happen to sit at that boundary — e.g. right after the closing `**`
    /// of a bold run. Called after every restyle pass and on every selection change, so the typing
    /// attributes are always the plain baseline; the next debounced restyle re-derives real
    /// styling for whatever the user actually typed.
    private func resetTypingAttributes() {
        textView.typingAttributes = [
            .font: MarkdownStyler.baseFont(),
            .foregroundColor: NSColor.labelColor,
        ]
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
    }
}
