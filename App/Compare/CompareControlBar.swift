import Cocoa

/// The thin control strip above the two comparison panes: hunk navigation, take-left/take-right,
/// and the parallel-reading and sync-scrolling toggles. Plain AppKit, matching the rest of the
/// app's "no SwiftUI in the editor surface" style — SwiftUI is reserved for the Settings panel.
final class CompareControlBar: NSView {

    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onTakeLeft: (() -> Void)?
    var onTakeRight: (() -> Void)?
    /// Passed the new state (`true` == parallel reading, decorations off).
    var onToggleParallel: ((Bool) -> Void)?
    /// Passed the new state (`true` == the panes scroll together). Off by default — see
    /// `CompareViewController.syncScrollingEnabled`.
    var onToggleSync: ((Bool) -> Void)?
    /// Stage 4's diff-summary command — the one AI feature that lives in the compare window rather
    /// than the main menu, since it needs both documents' hunks, which only this view computes.
    var onSummarizeChanges: (() -> Void)?

    private let background = NSVisualEffectView()
    private let divider = NSBox()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "No changes")
    private let takeLeftButton = NSButton()
    private let takeRightButton = NSButton()
    private let summarizeChangesButton = NSButton()
    private let parallelToggle = NSButton(checkboxWithTitle: "Parallel Reading", target: nil, action: nil)
    private let syncToggle = NSButton(checkboxWithTitle: "Sync Scrolling", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        background.material = .headerView
        background.blendingMode = .withinWindow
        background.state = .active
        divider.boxType = .separator

        previousButton.bezelStyle = .rounded
        previousButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous Change")
        previousButton.toolTip = "Jump to the previous change"
        previousButton.target = self
        previousButton.action = #selector(previousTapped)
        previousButton.setAccessibilityHelp(previousButton.toolTip)

        nextButton.bezelStyle = .rounded
        nextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next Change")
        nextButton.toolTip = "Jump to the next change"
        nextButton.target = self
        nextButton.action = #selector(nextTapped)
        nextButton.setAccessibilityHelp(nextButton.toolTip)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center

        takeLeftButton.bezelStyle = .rounded
        takeLeftButton.title = "Take Left ⬅"
        takeLeftButton.toolTip = "Apply the left side's version of the current change to the right"
        takeLeftButton.target = self
        takeLeftButton.action = #selector(takeLeftTapped)
        // The visible title's trailing arrow glyph is decorative punctuation for sighted users, not
        // meant to be spelled out — VoiceOver reading the title verbatim says "Take Left, leftwards
        // arrow", which is confusing rather than informative. An explicit label overrides that with
        // the same wording the tooltip already uses.
        takeLeftButton.setAccessibilityLabel("Take Left")
        takeLeftButton.setAccessibilityHelp(takeLeftButton.toolTip)

        takeRightButton.bezelStyle = .rounded
        takeRightButton.title = "Take Right ➡"
        takeRightButton.toolTip = "Apply the right side's version of the current change to the left"
        takeRightButton.target = self
        takeRightButton.action = #selector(takeRightTapped)
        takeRightButton.setAccessibilityLabel("Take Right")
        takeRightButton.setAccessibilityHelp(takeRightButton.toolTip)

        summarizeChangesButton.bezelStyle = .rounded
        summarizeChangesButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Summarize Changes")
        summarizeChangesButton.toolTip = "Summarize what changed, using on-device AI"
        summarizeChangesButton.target = self
        summarizeChangesButton.action = #selector(summarizeChangesTapped)
        summarizeChangesButton.setAccessibilityHelp(summarizeChangesButton.toolTip)

        parallelToggle.target = self
        parallelToggle.action = #selector(parallelToggled)
        parallelToggle.toolTip = "Show both documents side by side, without change highlighting"

        // Off by default: the panes scroll independently unless this is switched on — see
        // `CompareViewController.syncScrollingEnabled`. Scroll syncing and parallel reading are
        // independent knobs (sync is genuinely useful with highlighting still on, e.g. to read a
        // long document's changes side by side without losing your place), so this is its own
        // checkbox rather than folded into `parallelToggle`.
        syncToggle.target = self
        syncToggle.action = #selector(syncToggled)
        syncToggle.toolTip = "Scroll both panes together"

        let leftGroup = NSStackView(views: [previousButton, nextButton, statusLabel, summarizeChangesButton])
        leftGroup.spacing = 6
        let rightGroup = NSStackView(views: [takeLeftButton, takeRightButton, parallelToggle, syncToggle])
        rightGroup.spacing = 10

        // Added in back-to-front order: `NSView.subviews` draws index 0 first, so listing
        // background/divider before the button groups is what keeps them behind.
        for view in [background, divider, leftGroup, rightGroup] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),

            leftGroup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leftGroup.centerYAnchor.constraint(equalTo: centerYAnchor),

            rightGroup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightGroup.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        update(hunkCount: 0, currentIndex: -1)
    }

    func update(hunkCount: Int, currentIndex: Int) {
        if hunkCount == 0 {
            statusLabel.stringValue = "No changes"
        } else {
            statusLabel.stringValue = "Change \(currentIndex + 1) of \(hunkCount)"
        }
        let hasHunks = hunkCount > 0
        previousButton.isEnabled = hasHunks
        nextButton.isEnabled = hasHunks
        takeLeftButton.isEnabled = hasHunks
        takeRightButton.isEnabled = hasHunks
        let availability = AIServiceProvider.shared.availability
        summarizeChangesButton.isEnabled = hasHunks && availability.isAvailable
        summarizeChangesButton.toolTip = {
            guard hasHunks else { return "No changes to summarize" }
            switch availability {
            case .available: return "Summarize what changed, using on-device AI"
            case .unavailable(let explanation): return explanation
            }
        }()
        summarizeChangesButton.setAccessibilityHelp(summarizeChangesButton.toolTip)
    }

    @objc private func previousTapped() { onPrevious?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func takeLeftTapped() { onTakeLeft?() }
    @objc private func takeRightTapped() { onTakeRight?() }
    @objc private func parallelToggled() { onToggleParallel?(parallelToggle.state == .on) }
    @objc private func syncToggled() { onToggleSync?(syncToggle.state == .on) }
    @objc private func summarizeChangesTapped() { onSummarizeChanges?() }
}
