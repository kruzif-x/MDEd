import Cocoa
import MDEdCore

/// The two-file comparison view: two `ComparePaneViewController`s side by side in a split view,
/// with a thin control bar for hunk navigation, take-left/take-right, and the parallel-reading
/// toggle. Owns the whole diff lifecycle — recompute, decoration, and scroll sync — since both of
/// those inherently need both panes' text at once, which neither pane has on its own.
final class CompareViewController: NSViewController {

    private static let recomputeDebounce: TimeInterval = 0.15

    let leftDocument: Document
    let rightDocument: Document

    private let leftPane: ComparePaneViewController
    private let rightPane: ComparePaneViewController
    private let splitViewController = NSSplitViewController()
    private let controlBar = CompareControlBar()

    private var diffWorkItem: DispatchWorkItem?
    private var latestResult: LineDiffResult?
    private var latestHunks: [Hunk] = []
    private var alignmentMap: LineAlignmentMap?
    private var leftDocLines: DocumentLines?
    private var rightDocLines: DocumentLines?
    private var scrollMapper: ScrollOffsetMapper?
    private var currentHunkIndex = -1
    private var parallelReadingEnabled = false
    /// Off by default: the panes scroll independently unless the user opts in via the "Sync
    /// Scrolling" checkbox in `CompareControlBar`. This used to be unconditional (every scroll on
    /// either side always dragged the other along), which is exactly the behavior an actual user
    /// of this app reported not wanting as the default. `ScrollOffsetMapper`/`LineAlignmentMap`
    /// are untouched — sync, when turned on, still uses them; it just isn't forced anymore.
    private var syncScrollingEnabled = false
    private var isSyncingScroll = false
    private var scrollObservers: [NSObjectProtocol] = []
    private var hasFinishedInitialLoad = false
    /// Keeps both panes' line-number gutters in sync with the live Settings toggle — the
    /// comparison window's counterpart to `EditorViewController`'s own
    /// `UserDefaults.didChangeNotification` observer. Deliberately narrow: unlike the single
    /// editor, this view doesn't otherwise react live to Settings changes (font/measure), so this
    /// only ever touches line-number visibility, not the rest of `EditorSettings`.
    private var settingsObserver: NSObjectProtocol?

    init(leftDocument: Document, rightDocument: Document) {
        self.leftDocument = leftDocument
        self.rightDocument = rightDocument
        self.leftPane = ComparePaneViewController(document: leftDocument)
        self.rightPane = ComparePaneViewController(document: rightDocument)
        super.init(nibName: nil, bundle: nil)

        leftPane.onTextChanged = { [weak self] in self?.scheduleDiffRecompute() }
        rightPane.onTextChanged = { [weak self] in self?.scheduleDiffRecompute() }

        controlBar.onPrevious = { [weak self] in self?.jumpToHunk(direction: -1) }
        controlBar.onNext = { [weak self] in self?.jumpToHunk(direction: 1) }
        controlBar.onTakeLeft = { [weak self] in self?.applyCurrentHunk(direction: .takeLeft) }
        controlBar.onTakeRight = { [weak self] in self?.applyCurrentHunk(direction: .takeRight) }
        controlBar.onToggleParallel = { [weak self] enabled in self?.setParallelReadingEnabled(enabled) }
        controlBar.onToggleSync = { [weak self] enabled in self?.setSyncScrollingEnabled(enabled) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — this app has no storyboard/xib")
    }

    deinit {
        for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    // MARK: - View hierarchy

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))

        addChild(splitViewController)
        let leftItem = NSSplitViewItem(viewController: leftPane)
        let rightItem = NSSplitViewItem(viewController: rightPane)
        splitViewController.splitViewItems = [leftItem, rightItem]
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin

        controlBar.translatesAutoresizingMaskIntoConstraints = false
        let splitContainer = splitViewController.view
        splitContainer.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(controlBar)
        view.addSubview(splitContainer)

        NSLayoutConstraint.activate([
            controlBar.topAnchor.constraint(equalTo: view.topAnchor),
            controlBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlBar.heightAnchor.constraint(equalToConstant: 36),

            splitContainer.topAnchor.constraint(equalTo: controlBar.bottomAnchor),
            splitContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasFinishedInitialLoad else { return }
        hasFinishedInitialLoad = true
        leftPane.finishInitialSetup()
        rightPane.finishInitialSetup()
        recomputeDiffNow()
        observeScrolling()
        observeLineNumberSetting()
    }

    // MARK: - Line numbers

    private func observeLineNumberSetting() {
        applyLineNumberVisibility()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyLineNumberVisibility()
        }
    }

    private func applyLineNumberVisibility() {
        let visible = EditorSettings.current().showLineNumbers
        leftPane.setLineNumbersVisible(visible)
        rightPane.setLineNumbersVisible(visible)
    }

    // MARK: - Debounced recompute

    private func scheduleDiffRecompute() {
        diffWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recomputeDiffNow() }
        diffWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recomputeDebounce, execute: work)
    }

    private func recomputeDiffNow() {
        leftPane.restyleNow()
        rightPane.restyleNow()

        let leftLines = DocumentLines(leftPane.currentText)
        let rightLines = DocumentLines(rightPane.currentText)
        leftDocLines = leftLines
        rightDocLines = rightLines

        let result = diffLines(leftLines.lines, rightLines.lines)
        latestResult = result
        latestHunks = hunks(in: result)
        alignmentMap = LineAlignmentMap(result)

        applyDecorations()

        let leftHeights = leftPane.measuredLineHeights(matching: leftLines)
        let rightHeights = rightPane.measuredLineHeights(matching: rightLines)
        scrollMapper = ScrollOffsetMapper(alignment: alignmentMap!, leftLineHeights: leftHeights, rightLineHeights: rightHeights)

        clampCurrentHunkIndex()
        controlBar.update(hunkCount: latestHunks.count, currentIndex: currentHunkIndex)
    }

    /// Applies (or, in parallel-reading mode, clears) both decoration layers from the most recent
    /// diff result — factored out of `recomputeDiffNow()` so the parallel-reading toggle can call
    /// it without redoing the diff itself.
    private func applyDecorations() {
        guard !parallelReadingEnabled, let result = latestResult, let leftLines = leftDocLines, let rightLines = rightDocLines else {
            leftPane.textView.diffHighlights = []
            rightPane.textView.diffHighlights = []
            return
        }
        leftPane.textView.diffHighlights = DiffDecorator.lineHighlights(for: .left, entries: result.entries, lines: leftLines)
        rightPane.textView.diffHighlights = DiffDecorator.lineHighlights(for: .right, entries: result.entries, lines: rightLines)
        // Attribute-only — must never register undo or dirty either document. See
        // `withoutRegisteringUndo`'s doc comment; reads each pane's `document.undoManager`
        // directly for the same reason `ComparePaneViewController.restyleNow()` does.
        if let storage = leftPane.textView.textStorage {
            withoutRegisteringUndo(on: leftPane.document.undoManager) {
                DiffDecorator.applyWordHighlights(to: storage, side: .left, entries: result.entries, leftLines: leftLines, rightLines: rightLines)
            }
        }
        if let storage = rightPane.textView.textStorage {
            withoutRegisteringUndo(on: rightPane.document.undoManager) {
                DiffDecorator.applyWordHighlights(to: storage, side: .right, entries: result.entries, leftLines: leftLines, rightLines: rightLines)
            }
        }
        // Word-level highlights are attribute-only changes applied directly to the shared text
        // storage; TextKit 2's own display invalidation for that should be automatic, but an
        // explicit full-view invalidation here is cheap insurance against any partial-redraw
        // corner case leaving a stale glyph run on screen after this pass.
        leftPane.textView.needsDisplay = true
        rightPane.textView.needsDisplay = true
    }

    private func setParallelReadingEnabled(_ enabled: Bool) {
        parallelReadingEnabled = enabled
        // Word-level highlights are real text attributes; restyling first resets every attribute
        // to the plain markdown baseline (see `MarkdownStyler.restyle`), so re-running the
        // decoration pass from there is what makes toggling off actually remove them rather than
        // needing to track and reverse each individual range.
        leftPane.restyleNow()
        rightPane.restyleNow()
        applyDecorations()
    }

    private func clampCurrentHunkIndex() {
        if latestHunks.isEmpty {
            currentHunkIndex = -1
        } else {
            currentHunkIndex = min(max(currentHunkIndex, 0), latestHunks.count - 1)
        }
    }

    // MARK: - Scroll sync

    private func observeScrolling() {
        let leftClip = leftPane.scrollView.contentView
        let rightClip = rightPane.scrollView.contentView
        let leftObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: leftClip, queue: .main) { [weak self] _ in
            self?.syncScroll(from: .left)
        }
        let rightObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: rightClip, queue: .main) { [weak self] _ in
            self?.syncScroll(from: .right)
        }
        scrollObservers = [leftObserver, rightObserver]
    }

    private func syncScroll(from side: DiffSide) {
        guard syncScrollingEnabled, !isSyncingScroll, let mapper = scrollMapper else { return }
        isSyncingScroll = true
        defer { isSyncingScroll = false }
        switch side {
        case .left:
            let target = mapper.rightOffset(forLeftOffset: Double(leftPane.verticalOffset))
            rightPane.verticalOffset = CGFloat(target)
        case .right:
            let target = mapper.leftOffset(forRightOffset: Double(rightPane.verticalOffset))
            leftPane.verticalOffset = CGFloat(target)
        }
    }

    /// Turns scroll syncing on or off. Turning it *on* mid-session re-anchors the right pane to
    /// the left pane's currently visible line immediately — a one-time, explicit sync right at
    /// the moment of opt-in — rather than leaving the two panes at whatever independent positions
    /// they drifted to and letting the *next* scroll event yank one of them into alignment, which
    /// would read as a sudden, disorienting jump instead of a deliberate "align now". Turning it
    /// off does nothing to either pane's position — they simply stop following each other from
    /// here on.
    private func setSyncScrollingEnabled(_ enabled: Bool) {
        syncScrollingEnabled = enabled
        guard enabled else { return }
        syncScroll(from: .left)
    }

    // MARK: - Hunk navigation

    private func hunkAnchorLeftLine(_ index: Int) -> Double {
        let hunk = latestHunks[index]
        if let l = hunk.leftRange { return Double(l.lowerBound) }
        guard let alignmentMap, let r = hunk.rightRange else { return 0 }
        return alignmentMap.position(ofRight: Double(r.lowerBound))
    }

    private func jumpToHunk(direction: Int) {
        guard !latestHunks.isEmpty, let leftLines = leftDocLines else { return }
        let currentLine = Double(leftPane.topVisibleLineIndex(in: leftLines) ?? 0)
        let epsilon = 0.5
        let target: Int
        if direction > 0 {
            target = latestHunks.indices.first { hunkAnchorLeftLine($0) > currentLine + epsilon } ?? 0
        } else {
            target = latestHunks.indices.reversed().first { hunkAnchorLeftLine($0) < currentLine - epsilon } ?? (latestHunks.count - 1)
        }
        currentHunkIndex = target
        scrollToHunk(target)
        controlBar.update(hunkCount: latestHunks.count, currentIndex: currentHunkIndex)
    }

    private func scrollToHunk(_ index: Int) {
        guard latestHunks.indices.contains(index), let leftLines = leftDocLines, let rightLines = rightDocLines else { return }
        let hunk = latestHunks[index]
        if let l = hunk.leftRange {
            leftPane.scrollToAndSelect(lineRange: l, in: leftLines)
        }
        if let r = hunk.rightRange {
            rightPane.scrollToAndSelect(lineRange: r, in: rightLines)
        }
    }

    /// The hunk closest to wherever the user is currently looking (the left pane's topmost
    /// visible line) — what take-left/take-right operate on so the action always targets the
    /// change actually on screen, without requiring an explicit "select a hunk" step first.
    private func nearestHunkIndex() -> Int? {
        guard !latestHunks.isEmpty, let leftLines = leftDocLines else { return nil }
        let currentLine = Double(leftPane.topVisibleLineIndex(in: leftLines) ?? 0)
        return latestHunks.indices.min { abs(hunkAnchorLeftLine($0) - currentLine) < abs(hunkAnchorLeftLine($1) - currentLine) }
    }

    // MARK: - Take left / take right

    private func applyCurrentHunk(direction: HunkApplyDirection) {
        guard let result = latestResult, let index = nearestHunkIndex() ?? (latestHunks.indices.contains(currentHunkIndex) ? currentHunkIndex : nil) else { return }
        let hunk = latestHunks[index]
        let edit = MDEdCore.lineEdit(for: hunk, in: result, direction: direction)

        let losingPane = direction == .takeLeft ? rightPane : leftPane
        let losingLines = DocumentLines(losingPane.currentText)
        let realizedEdit = MDEdCore.textEdit(for: edit, in: losingLines)

        // Routed through `insertText(_:replacementRange:)` — the normal editing API — rather than
        // touching the text storage directly, so this registers as an ordinary, undoable edit on
        // whichever document is losing content, exactly like the user having typed it.
        losingPane.textView.insertText(realizedEdit.replacementText, replacementRange: realizedEdit.range.nsRange)

        currentHunkIndex = index
        recomputeDiffNow()
    }
}
