import Cocoa
import MDEdCore
import SwiftUI

/// Hosts the single `NSTextView` editor plus an unobtrusive status bar. Plain AppKit throughout —
/// no `NSViewRepresentable`, per the project's architecture notes.
final class EditorViewController: NSViewController {

    /// How long to wait after the last keystroke before re-parsing and restyling. Long enough that
    /// fast typing doesn't reparse on every character, short enough that styling feels immediate.
    private static let restyleDebounce: TimeInterval = 0.12

    /// How long to wait after the caret last moved before telling the outline sidebar which entry
    /// to highlight. Caret movement (arrow keys, clicks) fires far more often than a real edit does,
    /// so this gets its own debounce rather than running on every selection-change notification —
    /// same discipline `restyleDebounce` already applies to the restyle pass, just gated on a
    /// different, higher-frequency event.
    private static let outlineHighlightDebounce: TimeInterval = 0.12

    /// Fixed vertical breathing room so the first line isn't jammed under the title bar and the
    /// last line can scroll clear of the bottom. Not user-configurable — unlike the horizontal
    /// margin, this doesn't need to react to window width, just to feel generous.
    private static let verticalPadding: CGFloat = 32

    /// The smallest horizontal margin the measure ever shrinks to, even in a narrow window. Not
    /// private: `DocumentWindowController` reuses it to size the initial window so the default
    /// measure isn't cramped on first launch.
    static let minimumMargin: CGFloat = 32

    /// The narrowest the text container is ever allowed to get. `textContainerInset.width` applies
    /// to *both* edges, so the container ends up `viewportWidth - 2 * inset` wide — and during
    /// window setup the viewport is briefly at a placeholder size far narrower than
    /// `2 * minimumMargin`. Letting the container reach zero or below makes TextKit 2's viewport
    /// layout resolve a null text location and throw an uncaught exception, which crashed the app
    /// on every document open. The margin yields before the container does.
    private static let minimumContentWidth: CGFloat = 120

    /// The per-edge padding TextKit adds inside every line fragment. Deliberately **not** zero.
    ///
    /// Zero looked like the obviously-correct value: the measure's column math
    /// (`EditorSettings.measureWidthPoints(font:)`) already accounts for the exact width `N`
    /// columns need, so any nonzero `lineFragmentPadding` would eat into that budget and wrap one
    /// word early. That's what this used to be set to — and it was a second, independent crash
    /// bug hiding behind the container-width one `horizontalInset` already guards against.
    ///
    /// With `lineFragmentPadding` at exactly `0`, opening any document that (a) is short enough to
    /// fit entirely within one viewport (no scrolling needed) and (b) begins with `#`, `-`, or `*`
    /// as its very first character — i.e. almost any short Markdown file, since that's an ATX
    /// heading or a list marker — throws the exact
    /// `-[NSTextContentStorage locationFromLocation:withOffset:] received invalid location (null)`
    /// exception this app was chasing. Confirmed by bisection: neither the document's byte length
    /// alone, nor its Markdown styling (font size/weight/color — reproduces with styling fully
    /// disabled too), nor the specific short character matters; what flips the crash off in every
    /// trial is giving `lineFragmentPadding` *any* nonzero value, down to a fraction of a point.
    /// That points at CoreText's own `isSimpleRectangularTextContainerForStartingCharacterAtIndex:`
    /// fast path (visible in the crash backtrace) special-casing a zero-padding container in a way
    /// that occasionally resolves a nil location for a short, all-in-one-viewport layout — a real
    /// AppKit/TextKit 2 defect, not something this app can patch upstream, only avoid triggering.
    ///
    /// A small nonzero value sidesteps it while staying visually negligible; `horizontalInset`
    /// below subtracts it back out of the margin so the measure's column-exact width math still
    /// lands on exactly `N` columns instead of quietly losing `2 * lineFragmentPadding` of it.
    private static let lineFragmentPadding: CGFloat = 1

    private let scrollView = NSScrollView()
    private let textView: MarkdownTextView
    private let statusDivider = NSBox()
    private let statusBar = NSVisualEffectView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var lineNumberGutter: LineNumberGutterView?

    private var restyleWorkItem: DispatchWorkItem?
    private var containerWidthWorkItem: DispatchWorkItem?
    private var outlineHighlightWorkItem: DispatchWorkItem?
    private var settingsObserver: NSObjectProtocol?
    private var didSaveObserver: NSObjectProtocol?
    /// The settings snapshot `applyCurrentSettings()` last actually applied — see that method's
    /// doc comment for why this guard exists.
    private var lastAppliedSettings: EditorSettings?
    private var lastAppliedMeasureWidth: CGFloat = -1
    private var lastKnownAvailableWidth: CGFloat = -1
    /// The word-count/reading-time portion of the status line, cached so a caret move (which
    /// happens far more often than a text edit) doesn't have to re-run `WordCount.analyze`.
    private var cachedWordCountText: String = ""

    var currentText: String { textView.string }

    /// Notifies the document window's outline sidebar of a fresh restyle pass's source text — see
    /// `DocumentSplitViewController.wireOutline()`, which sets this. Called at the end of
    /// `restyleNow()`, so it shares that method's debounce rather than reparsing headings on every
    /// keystroke; `MDEdCore.TableOfContents`/`OutlineTree` do the actual (cheap, deterministic)
    /// re-derivation and bail out on their own if nothing heading-shaped changed.
    var onOutlineTextDidChange: ((String) -> Void)?

    /// Notifies the outline sidebar that the caret moved to a new UTF-16 offset, so it can update
    /// which entry is highlighted — debounced separately from `onOutlineTextDidChange` (see
    /// `outlineHighlightDebounce`) since caret motion is far more frequent than an edit.
    var onCaretDidMove: ((Int) -> Void)?

    /// Owns detaching `textView`'s layout manager from the document's shared content storage —
    /// see `TextLayoutAttachment`'s doc comment. Holding this alive for exactly as long as this
    /// view controller lives (nothing more, nothing less) is what makes the detach automatic:
    /// there's no manual cleanup call for `deinit` to remember, because this stored property's
    /// own `deinit` does it.
    private let layoutAttachment: TextLayoutAttachment

    /// Live-preview editing (hides Markdown markers off the cursor's line, renders
    /// tables/math/Mermaid inline) — see that type's doc comment. Unlike `layoutAttachment`, a
    /// reference to `document` *is* kept here (as `unowned`, matching `LivePreviewController`'s
    /// own — see that type for why `unowned` rather than `weak` is safe: this view controller
    /// never outlives the document, which strongly owns the window controller that owns it),
    /// because live preview needs `document.hasComparePane` on every recompute, not just at init.
    private let livePreviewController: LivePreviewController

    /// Kept for `restyleNow()` to reach `document.undoManager` directly rather than through
    /// `textView.undoManager`'s responder-chain resolution (window → window delegate →
    /// `NSWindowController.windowWillReturnUndoManager(_:)`). That chain does resolve to the same
    /// instance once the window is fully set up (confirmed: a real edit's undo action lands on
    /// `document.undoManager`, not some other instance) — but `restyleNow()`'s very first call, from
    /// `finishInitialSetup()`, runs synchronously inside `makeWindowControllers()`, before this
    /// view controller has any settled opinion on window-attachment timing. `document.undoManager`
    /// is unconditionally non-nil the moment `Document` exists (`NSDocument` creates it lazily on
    /// first access, independent of any window), so reading it here instead removes that timing
    /// question entirely rather than trusting it. `unowned`, matching `livePreviewController` above
    /// — same lifetime argument.
    private unowned let document: Document

    /// Review notes: anchored, sidecar-persisted annotations — see `ReviewNotesController`.
    /// Owned here (not on `Document`) because everything note-related lives in the editor's UI
    /// surface; the sidecar reload happens in `finishInitialSetup()` and re-resolution rides
    /// this controller's existing text-change debounce. `document` is referenced through the
    /// controller's own `unowned` handle — same lifetime argument as every property above.
    private let notesController: ReviewNotesController

    /// The one popover all note UI (composer, detail, list) reuses. Transient behavior closes
    /// it on any click outside; keeping the `NSPopover` object itself alive between shows is
    /// just how AppKit popovers are meant to be driven.
    private var notesPopover: NSPopover?

    /// `document` hands out a text container attached to its shared `NSTextContentStorage` — see
    /// `Document`'s documentation for why every view of a document must attach this way instead of
    /// owning an independent text storage. The container (and the attachment that keeps its
    /// layout manager alive/detachable, see `layoutAttachment`) are what `init` needs from it
    /// otherwise; `livePreviewController` and `document` are the other pieces that keep a
    /// reference to it beyond `init` — see their own property doc comments for why.
    init(document: Document) {
        // Explicit TextKit 2 stack, sharing `document.textContentStorage` rather than each view
        // creating its own private one (which `MarkdownTextView(usingTextLayoutManager: true)`
        // would do).
        let (container, attachment) = document.makeTextContainer()
        layoutAttachment = attachment
        textView = MarkdownTextView(frame: .zero, textContainer: container)
        livePreviewController = LivePreviewController(document: document)
        notesController = ReviewNotesController(document: document)
        self.document = document
        super.init(nibName: nil, bundle: nil)
        // Only the ordinary editor tab's layout manager gets live-preview treatment — a compare
        // pane never sets itself as this delegate, and `LivePreviewController` additionally
        // refuses to hide anything for as long as `document.hasComparePane` is true (see its
        // `isEnabled`), so a document shared between an editor tab and a comparison window still
        // renders correctly for the comparison side even with this assignment in place.
        document.textContentStorage.delegate = livePreviewController
        livePreviewController.onNeedsRedisplay = { [weak self] in
            // An async block image just finished (or a hidden/substituted marker's reveal state
            // just flipped), which can shift every line position below it — same class of "line
            // positions moved without an ordinary character-level edit driving it" as a
            // live-preview mode toggle, so it gets the same full-ruler treatment. See
            // `invalidateGutterFully()`.
            self?.invalidateGutterFully()
        }
        // `NSViewController` has no `viewDidChangeEffectiveAppearance()` hook of its own (only
        // `NSView` does) — `textView.onEffectiveAppearanceChange` is `MarkdownTextView`'s own
        // override of it, forwarded here. Covers both `EditorSettings.applyTheme()` setting
        // `NSApp.appearance` explicitly (Settings ▸ Theme: Light/Dark) and the system appearance
        // itself flipping while the setting is `.system` — no need to distinguish the two.
        // Rendered block images (tables/math/Mermaid) were drawn for whatever appearance was
        // active when each was last rendered (see `BlockImageRenderer.Appearance`), so every one
        // of them needs to be redone now that it no longer matches.
        textView.onEffectiveAppearanceChange = { [weak self] in
            self?.livePreviewController.appearanceDidChange()
        }
        notesController.onDidChange = { [weak self] in
            self?.syncNotesPresentation()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — this app has no storyboard/xib")
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let didSaveObserver {
            NotificationCenter.default.removeObserver(didSaveObserver)
        }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 920, height: 720))
        configureTextView()
        configureStatusBar()
        configureLayout()
        observeSettingsChanges()
        observeDocumentSaves()
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
        // Clamped even here: this runs before first layout, when the view still carries
        // `loadView()`'s placeholder frame, which can be narrower than `2 * minimumMargin`.
        textView.textContainerInset = NSSize(
            width: Self.horizontalInset(available: textView.bounds.width, measure: .greatestFiniteMagnitude),
            height: Self.verticalPadding
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        // See `Self.lineFragmentPadding` for why this is a small nonzero value rather than the
        // `0` that would make the measure's column math exact on its own.
        textView.textContainer?.lineFragmentPadding = Self.lineFragmentPadding
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // The native find bar (⌘F), driven by the Find menu built in AppDelegate.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.delegate = self
        textView.setAccessibilityLabel("Markdown source")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        configureLineNumberGutter()
    }

    /// Installs `lineNumberGutter` as the scroll view's vertical ruler. The ruler is always
    /// created and attached — only `rulersVisible` toggles per `EditorSettings.showLineNumbers` —
    /// so flipping the setting later is just a visibility flip plus a re-tile, not a rebuild.
    private func configureLineNumberGutter() {
        let gutter = LineNumberGutterView(textView: textView, scrollView: scrollView)
        lineNumberGutter = gutter
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = EditorSettings.current().showLineNumbers
        gutter.onNoteClick = { [weak self, weak gutter] _, noteID, markerRect in
            guard let self, let gutter else { return }
            self.presentNoteDetail(noteID: noteID, relativeTo: markerRect, of: gutter)
        }
    }

    /// Notes made in an unsaved document live in memory only until it first gets a file URL;
    /// every save (autosave included — the controller itself skips writes when nothing
    /// changed) is the moment to carry them to the sidecar.
    private func observeDocumentSaves() {
        didSaveObserver = NotificationCenter.default.addObserver(
            forName: Document.didSaveMDEdNotification, object: document, queue: .main
        ) { [weak self] _ in
            self?.notesController.persistNow()
        }
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
        // The label's own text already reads sensibly ("142 words · 1 min · Ln 3, Col 12"), but a
        // fixed accessibility label names what kind of status this is *before* VoiceOver reads the
        // current value — otherwise a screen reader landing here for the first time has no context
        // for what the numbers mean.
        statusLabel.setAccessibilityLabel("Word count and cursor position")
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

    /// The document's text is already present in the shared content storage this view's text
    /// container was built from (see `Document.makeTextContainer()`) by the time this view exists
    /// — nothing needs to be assigned here. This just runs the styling/status passes that would
    /// otherwise wait for the first debounced edit, so a freshly opened document isn't briefly
    /// shown unstyled.
    func finishInitialSetup() {
        notesController.reloadFromSidecar()
        restyleNow()
        updateStatusNow()
    }

    // MARK: - Measure (constrained, centered text column)

    /// Caps the text container at `EditorSettings.measureWidth` and centers it by growing
    /// `textContainerInset`'s horizontal component — a wider window becomes more margin, not a
    /// longer line. Below `measureWidth + 2 * minimumMargin` the margin shrinks down to
    /// `minimumMargin` and the line itself narrows, which is the graceful behavior for a small
    /// window rather than clipping or forcing a horizontal scrollbar.
    /// The per-edge inset that centres a `measure`-wide column in an `available`-wide viewport,
    /// clamped so the container it leaves behind is never narrower than `minimumContentWidth`.
    /// Every assignment to `textContainerInset.width` must come through here — see that constant
    /// for what a non-positive container width does to TextKit 2.
    ///
    /// Subtracts `lineFragmentPadding` from both the ideal and the affordability floor: the text
    /// container itself is `available - 2 * inset` wide, but the glyphs' actual usable width is
    /// `2 * lineFragmentPadding` narrower still (TextKit eats that much off each line fragment
    /// regardless of `inset`). Folding it in here — once — is what keeps `measure` landing on
    /// exactly `N` columns and keeps the guaranteed-usable width at a true `minimumContentWidth`,
    /// even though `lineFragmentPadding` itself is now nonzero (see that constant for why).
    static func horizontalInset(available: CGFloat, measure: CGFloat) -> CGFloat {
        let ideal = max(minimumMargin, (available - measure) / 2 - lineFragmentPadding)
        let maxAffordable = max(0, (available - minimumContentWidth) / 2 - lineFragmentPadding)
        return min(ideal, maxAffordable)
    }

    private func updateMeasure() {
        // `textView.bounds.width`, not `scrollView.contentView.bounds.width`: the two coincide
        // when there's no ruler, but `NSScrollView` reserves the vertical ruler's `ruleThickness`
        // out of the *document view*'s width while leaving `contentView.bounds` reporting the
        // scroll view's full width regardless — confirmed by direct measurement, not assumed.
        // Centering against the wrong (too-wide) `available` was computing a stale inset that
        // left the ruler's width silently eaten out of the measure itself instead of the margin,
        // which is exactly the "gutter breaks the measure" hazard this method exists to avoid.
        let available = textView.bounds.width
        guard available > 1 else { return }

        let settings = EditorSettings.current()
        let measure = settings.measureWidthPoints(font: MarkdownStyler.baseFont(settings))

        // Recompute when either input actually moved. The previous version assigned
        // `lastKnownAvailableWidth = available` before comparing the two, so the width
        // half of this test was always false and a plain window resize never re-centred.
        //
        // The threshold is deliberately tiny (not, say, `0.5`) — anything coarser can leave the
        // *final* frame of an animated width change (a split-view sidebar collapsing/expanding,
        // in particular) unapplied. That animation settles through a handful of `viewDidLayout()`
        // calls with steadily shrinking deltas between them; a last step landing exactly on the
        // threshold (observed directly: `1053.0 → 1052.5`, a 0.5pt delta that a strict `> 0.5`
        // test does not count as "changed") left this method applying an inset computed from the
        // second-to-last width forever, one animation frame short of the truly settled one — never
        // wrong enough to violate `horizontalInset`'s own centering math (the container width it
        // produces is provably invariant to `available` in the unclamped regime either way), but
        // wrong enough to leave the *typing caret’s* container origin a fraction of a point off
        // from where a fresh launch at the same final size would put it, which is a real,
        // user-visible difference this method exists to prevent, not something to tolerate.
        let widthChanged = abs(available - lastKnownAvailableWidth) > 0.05
        let measureChanged = measure != lastAppliedMeasureWidth
        guard widthChanged || measureChanged || lastAppliedMeasureWidth < 0 else { return }

        lastKnownAvailableWidth = available
        lastAppliedMeasureWidth = measure

        textView.textContainerInset = NSSize(
            width: Self.horizontalInset(available: available, measure: measure),
            height: textView.textContainerInset.height
        )

        // Every wrapped line's fragment count can change with the measure — same "line positions
        // moved without a character-level edit driving it" class of problem `invalidateGutterFully`
        // exists for (see that method's doc comment, which calls this case out by name).
        invalidateGutterFully()
        scheduleContainerWidthUpdate()
    }

    /// The text container's *content* width in points — `textView.bounds.width` minus both
    /// insets (`updateMeasure()`'s centering margin) and both edges' `lineFragmentPadding` (see
    /// that constant's doc comment for why it's subtracted here too: it's real space TextKit eats
    /// off each line fragment regardless of the inset). This is the actual usable measure a
    /// rendered block image should target — not `textView.bounds.width` itself, which would render
    /// tables wider than the text column they sit inside.
    private func contentWidth() -> CGFloat {
        max(0, textView.bounds.width - 2 * textView.textContainerInset.width - 2 * Self.lineFragmentPadding)
    }

    /// Debounces telling `livePreviewController` about a new container width — a live window-resize
    /// drag calls `updateMeasure()` on every layout pass, and forwarding each one immediately would
    /// queue a burst of redundant `BlockImageRenderer` requests (each superseded before it could
    /// even finish) instead of one settled request once the drag pauses. Shares
    /// `Self.restyleDebounce`'s interval, not its work item — an in-flight restyle and an in-flight
    /// width update are independent and shouldn't cancel each other.
    private func scheduleContainerWidthUpdate() {
        containerWidthWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.livePreviewController.containerWidthDidChange(self.contentWidth())
        }
        containerWidthWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restyleDebounce, execute: work)
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
    ///
    /// Bails immediately if nothing this app cares about actually changed. `UserDefaults`'s
    /// `didChangeNotification` fires for *any* write to the domain, by *any* framework — not just
    /// this app's own Settings panel. `BlockImageRenderer`'s first `WKWebView` triggers exactly
    /// that: WebKit's `WebProcessPool` init calls its own `-[NSUserDefaults registerDefaults:]`
    /// internally, which posts this same notification, landing right back here. Before this guard
    /// existed, that one spurious notification re-ran a full restyle *and* a full live-preview
    /// recompute (reparsing, rebuilding the display mapper, re-requesting every table/math/Mermaid
    /// render already in flight) for no reason — observed directly via this file's temporary
    /// logging as a burst of repeated identical work at launch, not an infinite loop (it was
    /// self-limiting), but real, avoidable churn `EditorSettings.Equatable` makes trivial to skip.
    private func applyCurrentSettings() {
        let settings = EditorSettings.current()
        guard settings != lastAppliedSettings else { return }
        lastAppliedSettings = settings
        textView.font = MarkdownStyler.baseFont(settings)
        resetTypingAttributes()
        // Ruler visibility first: a visible gutter reserves real horizontal space out of
        // `textView.bounds.width` — see the comment on `updateMeasure()`'s `available` for how
        // that's wired up — and `updateMeasure()` below needs to see that *new* width, not the
        // one from before the toggle, or the measure stays centered on the stale viewport for one
        // frame and only catches up on the next resize instead of recentering immediately.
        // `scrollView.tile()` forces `NSScrollView` to resolve the ruler's reserved width
        // synchronously rather than waiting for its own next layout pass.
        scrollView.rulersVisible = settings.showLineNumbers
        scrollView.tile()
        lineNumberGutter?.updateThickness()
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
            // Same debounce, deliberately after the restyle pass: re-resolving note anchors
            // is exactly the class of derived work (like outline text) that should track
            // edits at typing cadence, not keystroke cadence.
            self?.notesController.recompute()
        }
        restyleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restyleDebounce, execute: work)
    }

    private func restyleNow() {
        guard let textStorage = textView.textStorage else { return }
        let settings = EditorSettings.current()
        // Attribute-only — must never register undo or dirty the document. See
        // `withoutRegisteringUndo`'s doc comment (and `document`'s own doc comment for why this
        // reads `document.undoManager` rather than `textView.undoManager`).
        var decorations: [BlockDecoration] = []
        withoutRegisteringUndo(on: document.undoManager) {
            decorations = MarkdownStyler.restyle(textStorage, settings: settings)
        }
        textView.blockDecorations = decorations
        resetTypingAttributes()
        // A real edit (or the very first call, from `finishInitialSetup`) — full live-preview
        // recompute, sharing this same debounce rather than reparsing on every keystroke.
        livePreviewController.textDidChange(newSource: textStorage.string, cursorOffset: textView.selectedRange().location)
        syncGutterCollapsedLines()
        lineNumberGutter?.updateThickness()
        invalidateGutterFully()
        onOutlineTextDidChange?(textStorage.string)
    }

    /// Forces the entire line-number gutter to redraw, discarding whatever partial dirty-region
    /// AppKit's own tracking would otherwise settle for. A plain `lineNumberGutter?.needsDisplay =
    /// true` marks this view's *bounds at the moment of the call* dirty — correct for an ordinary
    /// text edit, where nothing shifts line positions by more than the edit itself touched. It's
    /// not enough for anything that can move many lines' worth of vertical position in one shot
    /// without the character-level edit machinery driving it: toggling live-preview mode (which
    /// can collapse or reveal a large block's continuation lines all at once), an async block image
    /// finishing (same, scoped to just its own block, but the ruler's total content height still
    /// moves), or a measure change (every wrapped line's fragment count can change). In each case
    /// TextKit 2's own re-layout — which is what actually resizes the scroll view's document view,
    /// and with it this ruler — can still be pending the moment `needsDisplay = true` is set, so
    /// the display pass that consumes that flag paints the ruler at its *old* size; nothing then
    /// re-dirties the region that grows or moves once layout catches up, leaving stale pixels from
    /// the previous paragraph positions showing through the new ones. Retiling synchronously first
    /// (so any resize that's already resolvable happens before the mark), then marking dirty twice
    /// — once now, once again after this run loop turn, by which point TextKit's deferred layout
    /// has had a chance to finish — covers both the immediate and the delayed case.
    private func invalidateGutterFully() {
        scrollView.tile()
        lineNumberGutter?.needsDisplay = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollView.tile()
            self.lineNumberGutter?.needsDisplay = true
        }
    }

    /// Mirrors `livePreviewController.collapsedContinuationLineIndices` onto the gutter — see
    /// `LineNumberGutterView.collapsedContinuationLineIndices` for the "one number per collapsed
    /// block, not one per source line" decision this exists to implement.
    private func syncGutterCollapsedLines() {
        lineNumberGutter?.collapsedContinuationLineIndices = livePreviewController.collapsedContinuationLineIndices
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
        let cursor = textView.selectedRange().location
        let (line, column) = lineAndColumn(at: cursor)
        statusLabel.stringValue = "\(cachedWordCountText) · Ln \(line), Col \(column)"
        // Cursor motion alone (no text change) — the cheap live-preview recompute path, which
        // reuses the last parse and only reconsiders which line the cursor now falls on.
        livePreviewController.selectionDidChange(cursorOffset: cursor)
        syncGutterCollapsedLines()
        scheduleOutlineHighlightUpdate(caretOffset: cursor)
    }

    /// Debounces telling the outline sidebar which entry now contains the caret — see
    /// `outlineHighlightDebounce`'s doc comment for why this needs its own debounce separate from
    /// the restyle pass's.
    private func scheduleOutlineHighlightUpdate(caretOffset: Int) {
        outlineHighlightWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onCaretDidMove?(caretOffset)
        }
        outlineHighlightWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.outlineHighlightDebounce, execute: work)
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

    // MARK: - Review notes

    /// Pushes the notes controller's current state into the two surfaces that visualize it:
    /// the text-column bars (`noteHighlights`) and the gutter dots (`noteMarkers`). Both
    /// properties invalidate display themselves; nothing here edits text or attributes.
    private func syncNotesPresentation() {
        textView.noteHighlights = notesController.highlightRanges()
        lineNumberGutter?.noteMarkers = notesController.gutterMarkers(in: DocumentLines(currentText))
    }

    /// Notes ▸ Add Note to Selection (and the toolbar button): opens the composer popover
    /// anchored at the selection. The anchor is captured from the *current* selection at
    /// save time (not at popover-open time), so text typed while the popover is up can't
    /// strand the anchor on a stale range.
    @objc func addNote(_ sender: Any?) {
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return }
        presentNoteComposer(selection: selection, editing: nil)
    }

    /// Notes ▸ Show All Notes (and the toolbar button): the one surface where unmatched
    /// notes — which have no location, so no bar and no gutter dot — remain reachable.
    @objc func showAllNotes(_ sender: Any?) {
        presentNotesPopover(content: {
            NotesListView(
                rows: makeNotesListRows(),
                onSelect: { [weak self] id in
                    self?.revealNote(id)
                    self?.notesPopover?.close()
                },
                onEdit: { [weak self] id in
                    self?.beginEditingNote(id: id)
                },
                onDelete: { [weak self] id in
                    guard let self else { return }
                    self.notesController.removeNote(id: id)
                    // Re-present the list so the deleted row disappears immediately instead
                    // of lingering in the already-open popover until the next open.
                    self.showAllNotes(nil)
                }
            )
        }, relativeTo: selectionAnchorRect(), of: textView, preferredEdge: .minY)
    }

    /// Scrolls a note's anchored passage into view and selects it — the list's and the detail
    /// popover's "go look at it" affordance. No-op for unmatched notes; for ambiguous ones it
    /// reveals the first candidate, which the note's displayed status has already flagged as
    /// a guess (`NoteAnchorResolution.primaryRange` documents that policy).
    func revealNote(_ id: UUID) {
        guard let range = notesController.primaryRange(for: id) else { return }
        textView.scrollRangeToVisible(range.nsRange)
        textView.setSelectedRange(range.nsRange)
        view.window?.makeFirstResponder(textView)
    }

    private func beginEditingNote(id: UUID) {
        guard let note = notesController.note(id: id) else { return }
        // Editing swaps the open popover's content for the composer rather than stacking a
        // second popover; anchored where the note's passage currently sits.
        let anchorRange = notesController.primaryRange(for: id).map { $0.nsRange } ?? textView.selectedRange()
        presentNoteComposer(selection: anchorRange, editing: note)
    }

    /// The composer popover for a brand-new note (anchored to `selection`) or an existing one
    /// (`editing`, whose anchor never changes — only its text does).
    private func presentNoteComposer(selection: NSRange, editing note: ReviewNote?) {
        let ns = textView.string as NSString
        let excerpt = ns.substring(with: NSRange(location: selection.location, length: min(selection.length, 140)))
        presentNotesPopover(content: {
            NoteEditorView(
                excerpt: excerpt,
                saveLabel: note == nil ? "Add Note" : "Save",
                initialText: note?.text ?? "",
                onSave: { [weak self] text in
                    guard let self else { return }
                    if let note {
                        self.notesController.updateNote(id: note.id, text: text)
                    } else {
                        _ = self.notesController.addNote(text, selection: MDEdCore.TextRange(lowerBound: selection.location, upperBound: selection.location + selection.length))
                    }
                    self.notesPopover?.close()
                },
                onCancel: { [weak self] in
                    self?.notesPopover?.close()
                }
            )
        }, relativeTo: selectionAnchorRect(for: selection), of: textView, preferredEdge: .minY)
    }

    /// The gutter dot's popover: one note, its drift status, and what to do about it.
    private func presentNoteDetail(noteID: UUID, relativeTo rect: NSRect, of view: NSView) {
        guard let note = notesController.note(id: noteID) else { return }
        let row = NotesListRow(
            id: note.id,
            kind: NoteStatusKind(notesController.resolution(for: noteID)),
            lineLabel: lineLabel(for: noteID),
            noteText: note.text,
            excerpt: note.anchor.text
        )
        presentNotesPopover(content: {
            NoteDetailView(
                row: row,
                onReveal: { [weak self] in
                    self?.revealNote(noteID)
                    self?.notesPopover?.close()
                },
                onEdit: { [weak self] in
                    self?.beginEditingNote(id: noteID)
                },
                onDelete: { [weak self] in
                    self?.notesController.removeNote(id: noteID)
                    self?.notesPopover?.close()
                }
            )
        }, relativeTo: rect, of: view, preferredEdge: .maxX)
    }

    /// Shows (or re-targets) the single shared notes popover. Replacing
    /// `contentViewController` on an already-shown popover is what lets "Edit…" swap a list
    /// or detail view for the composer in place, without stacking popovers.
    private func presentNotesPopover(
        @ViewBuilder content: () -> some View,
        relativeTo rect: NSRect,
        of view: NSView,
        preferredEdge: NSRectEdge
    ) {
        let popover = notesPopover ?? NSPopover()
        notesPopover = popover
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: content())
        popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
    }

    /// The on-screen rect of the current selection (or caret) in `textView`'s coordinates —
    /// what note popovers anchor to when they're about something the user selected.
    private func selectionAnchorRect() -> NSRect {
        selectionAnchorRect(for: textView.selectedRange())
    }

    private func selectionAnchorRect(for range: NSRange) -> NSRect {
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        let windowRect = view.window?.convertFromScreen(screenRect) ?? screenRect
        return textView.convert(windowRect, from: nil)
    }

    private func makeNotesListRows() -> [NotesListRow] {
        notesController.notes.map { note in
            NotesListRow(
                id: note.id,
                kind: NoteStatusKind(notesController.resolution(for: note.id)),
                lineLabel: lineLabel(for: note.id),
                noteText: note.text,
                excerpt: note.anchor.text
            )
        }
    }

    private func lineLabel(for noteID: UUID) -> String? {
        guard let range = notesController.primaryRange(for: noteID) else { return nil }
        let lines = DocumentLines(currentText)
        guard let line = lines.lineIndex(atUTF16Offset: range.lowerBound) else { return nil }
        return "Ln \(line + 1)"
    }

    // MARK: - AI commands

    /// Every AI command routes through here: run `runner` (already bound to the specific command),
    /// present its result via `AIReview`, and — only if the user explicitly clicks the apply
    /// button — replace `applyRange` with the result through `insertText(_:replacementRange:)`, the
    /// same ordinary, undoable editing path every other command in this file uses. Nothing here
    /// ever touches `textView`'s content on its own; see `AIReview`'s own doc comment.
    private func presentAIReview(
        title: String,
        applyLabel: String?,
        applyRange: NSRange?,
        operation: @escaping (@escaping (AIProgress) -> Void) async throws -> AICommandResult
    ) {
        guard let window = view.window else { return }
        AIReview.present(
            title: title,
            applyLabel: applyLabel,
            over: window,
            operation: operation,
            onApply: applyRange.map { range in
                { [weak self] result in
                    guard let self else { return }
                    self.textView.insertText(result, replacementRange: range)
                    self.scheduleRestyleAndStatus()
                }
            }
        )
    }

    @objc func aiSummarizeDocument(_ sender: Any?) {
        let text = textView.string
        let runner = AICommandRunner(service: AIServiceProvider.shared)
        presentAIReview(
            title: "Summarize Document",
            applyLabel: "Insert at Cursor",
            applyRange: textView.selectedRange()
        ) { progress in
            AICommandResult(text: try await runner.summarizeDocument(text, progress: progress), markupDelta: nil)
        }
    }

    @objc func aiTightenSelection(_ sender: Any?) {
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return }
        let text = (textView.string as NSString).substring(with: selection)
        let runner = AICommandRunner(service: AIServiceProvider.shared)
        presentAIReview(
            title: "Tighten Selection",
            applyLabel: "Replace Selection",
            applyRange: selection
        ) { _ in try await runner.tighten(text) }
    }

    @objc func aiTranslateSelection(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? String else { return }
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return }
        let text = (textView.string as NSString).substring(with: selection)
        let runner = AICommandRunner(service: AIServiceProvider.shared)
        presentAIReview(
            title: "Translate Selection to \(language)",
            applyLabel: "Replace Selection",
            applyRange: selection
        ) { progress in try await runner.translate(text, to: language, progress: progress) }
    }

    @objc func aiTranslateDocument(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? String else { return }
        let text = textView.string
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let runner = AICommandRunner(service: AIServiceProvider.shared)
        presentAIReview(
            title: "Translate Document to \(language)",
            applyLabel: "Replace Document",
            applyRange: fullRange
        ) { progress in try await runner.translate(text, to: language, progress: progress) }
    }

    // MARK: - Outline sidebar navigation

    /// Scrolls `range` into view and places a zero-length caret at its start — the outline
    /// sidebar's "jump to this heading" affordance (`DocumentSplitViewController.wireOutline()`
    /// calls this from `OutlineViewController.onSelectEntry`). A caret, not a selection of the
    /// whole heading line: the point is that the keyboard lands somewhere useful immediately
    /// afterward, not that the heading text itself is selected (which would make the user's very
    /// next keystroke overtype it). `setSelectedRange` posts the same
    /// `NSTextView.didChangeSelectionNotification` a mouse click does, so `textViewDidChangeSelection`
    /// below runs its usual caret-driven work (typing attributes, status line, live-preview,
    /// outline re-highlight) without anything here duplicating it.
    func revealAndPlaceCaret(at range: MDEdCore.TextRange) {
        textView.scrollRangeToVisible(range.nsRange)
        textView.setSelectedRange(NSRange(location: range.lowerBound, length: 0))
        view.window?.makeFirstResponder(textView)
    }

    // MARK: - Deterministic commands (not model-generated — see `TableOfContents`/`MarkdownFormatting`)

    /// Inserts a Markdown bullet list of the document's headings at the cursor (replacing the
    /// selection, if any) — an ordinary, instant, undoable edit like the toolbar formatting
    /// commands above, not an AI review: there's nothing probabilistic to review here.
    @objc func insertTableOfContents(_ sender: Any?) {
        let entries = TableOfContents.entries(from: textView.string)
        guard !entries.isEmpty else { return }
        let markdown = TableOfContents.renderMarkdown(entries) + "\n"
        let selection = textView.selectedRange()
        textView.insertText(markdown, replacementRange: selection)
        scheduleRestyleAndStatus()
    }

    /// Normalizes the whole document's Markdown formatting in one instant, undoable edit — see
    /// `MarkdownFormatting.normalize(_:)` for exactly what it does and doesn't touch.
    @objc func normalizeFormatting(_ sender: Any?) {
        let current = textView.string
        let normalized = MarkdownFormatting.normalize(current)
        guard normalized != current else { return }
        let fullRange = NSRange(location: 0, length: (current as NSString).length)
        textView.insertText(normalized, replacementRange: fullRange)
        scheduleRestyleAndStatus()
    }
}

// MARK: - NSTextViewDelegate

extension EditorViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        scheduleRestyleAndStatus()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        resetTypingAttributes()
        updateCursorPositionOnly()
    }
}

// MARK: - NSMenuItemValidation

/// Disables each AI/format command when it wouldn't make sense to invoke right now — an empty
/// document, no selection, or (for the AI commands specifically) the model being unavailable —
/// rather than letting the command run and fail, or silently do nothing. See
/// `AppDelegate.aiMenuNeedsUpdate` for the menu-level diagnostic item this pairs with.
extension EditorViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasDocumentContent = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSelection = textView.selectedRange().length > 0

        switch menuItem.action {
        case #selector(aiSummarizeDocument(_:)), #selector(aiTranslateDocument(_:)):
            return AIServiceProvider.shared.availability.isAvailable && hasDocumentContent
        case #selector(aiTightenSelection(_:)), #selector(aiTranslateSelection(_:)):
            return AIServiceProvider.shared.availability.isAvailable && hasSelection
        case #selector(insertTableOfContents(_:)):
            return !TableOfContents.entries(from: textView.string).isEmpty
        case #selector(normalizeFormatting(_:)):
            return hasDocumentContent
        case #selector(addNote(_:)):
            // Whitespace-only selections can't be anchored (`makeAnchor` rejects them); the
            // guard in `addNote` itself re-checks, this just keeps the menu honest.
            return hasSelection
        case #selector(showAllNotes(_:)):
            return notesController.hasNotes
        default:
            return true
        }
    }
}
