import Cocoa
import MDEdCore

/// The document window's outline sidebar content: a native `NSOutlineView` of the document's
/// headings, nested by level, inside an `NSVisualEffectView` giving it the standard `.sidebar`
/// material and translucency. Hosted as the leading item of `DocumentSplitViewController`.
///
/// All the actual parsing/nesting/caret-mapping logic lives in `MDEdCore.OutlineTree` and
/// `TableOfContents` — this type is deliberately thin: it owns the `NSOutlineView` plumbing (data
/// source, row views, selection↔caret bridging) and nothing else. See those types' own tests for
/// the logic this defers to.
final class OutlineViewController: NSViewController {

    /// One row's worth of state for `NSOutlineView`'s item-based data source. A plain `NSObject`
    /// subclass, not `MDEdCore.OutlineNode` itself: `NSOutlineView` identifies items by reference
    /// (`isEqual`/hash, which an unadorned `NSObject` gets as pointer identity) for
    /// `expandItem`/`row(forItem:)`/selection — a value type would need extra machinery to behave
    /// the same way, and this project already prefers a thin class wrapper over that for the same
    /// TextKit-adjacent reasons `TextLayoutAttachment` documents.
    private final class Row: NSObject {
        let entry: TOCEntry
        let entryIndex: Int
        let children: [Row]

        init(node: OutlineNode) {
            entry = node.entry
            entryIndex = node.entryIndex
            children = node.children.map(Row.init)
        }
    }

    private static let rowCellIdentifier = NSUserInterfaceItemIdentifier("OutlineRowCell")
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("OutlineColumn")

    private let effectView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let emptyStateLabel = NSTextField(labelWithString: "No headings in this document")

    /// The flat entry list the outline is currently showing — kept alongside `roots` so
    /// `highlightEntry(containingCaret:)` can call straight into `OutlineTree.containingEntryIndex`
    /// without re-deriving it from the row tree.
    private var currentEntries: [TOCEntry] = []
    private var roots: [Row] = []
    /// Every row, keyed by its position in `currentEntries` — lets `highlightEntry(containingCaret:)`
    /// go straight from "entry index" to "the exact `Row` instance the outline view knows about"
    /// without a tree walk, and lets `outlineView.row(forItem:)` report `-1` correctly (rather than
    /// this code guessing) when that row is currently inside a collapsed, invisible section.
    private var rowsByEntryIndex: [Int: Row] = [:]

    /// Set for the duration of a *programmatic* selection change (driven by
    /// `highlightEntry(containingCaret:)`, i.e. the user moved the caret in the text view) so
    /// `outlineViewSelectionDidChange` can tell that apart from a *user-driven* one (a click or an
    /// arrow key inside the outline itself) and only forward the latter to `onSelectEntry` — without
    /// this, every caret move would echo back into the text view as a "jump to this heading",
    /// fighting the very caret movement that triggered it.
    private var isApplyingProgrammaticSelection = false

    /// Called when the user picks a row (click or keyboard) — never for the programmatic selection
    /// `highlightEntry(containingCaret:)` makes. The caller (`DocumentSplitViewController`) uses
    /// this to scroll the editor to `entry.range` and place the caret there.
    var onSelectEntry: ((TOCEntry) -> Void)?

    override func loadView() {
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        effectView.state = .followsWindowActiveState
        view = effectView

        configureOutlineView()
        configureEmptyState()
        configureLayout()
        updateEmptyState()
    }

    private func configureOutlineView() {
        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.title = "Outline"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.setAccessibilityLabel("Document outline")

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
    }

    private func configureEmptyState() {
        emptyStateLabel.font = .systemFont(ofSize: 12)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.lineBreakMode = .byWordWrapping
        emptyStateLabel.maximumNumberOfLines = 0
        emptyStateLabel.setAccessibilityLabel("No headings in this document")
    }

    private func configureLayout() {
        for subview in [scrollView, emptyStateLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            effectView.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: effectView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),

            emptyStateLabel.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 16),
            emptyStateLabel.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -16),
        ])
    }

    // MARK: - Content

    /// Rebuilds the outline from `text`'s current headings. Called by `EditorViewController` on the
    /// same debounce as its restyle pass (see `EditorViewController.onOutlineTextDidChange`) — never
    /// on every keystroke.
    ///
    /// Bails out when the heading list hasn't actually changed (`TOCEntry` is `Equatable`), so an
    /// edit that doesn't touch any heading — the overwhelming majority of edits — doesn't reload the
    /// outline view or disturb whatever the user has expanded/collapsed by hand.
    func update(text: String) {
        let newEntries = TableOfContents.entries(from: text)
        guard newEntries != currentEntries else { return }
        currentEntries = newEntries

        let tree = OutlineTree.build(from: newEntries).map(Row.init)
        roots = tree
        var index: [Int: Row] = [:]
        Self.flatten(tree, into: &index)
        rowsByEntryIndex = index

        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        updateEmptyState()
    }

    private static func flatten(_ rows: [Row], into index: inout [Int: Row]) {
        for row in rows {
            index[row.entryIndex] = row
            flatten(row.children, into: &index)
        }
    }

    private func updateEmptyState() {
        let isEmpty = currentEntries.isEmpty
        scrollView.isHidden = isEmpty
        emptyStateLabel.isHidden = !isEmpty
    }

    /// Selects (without scrolling the caller's editor, and without re-triggering `onSelectEntry`)
    /// the row for the heading section that UTF-16 offset `caretOffset` currently falls under —
    /// see `MDEdCore.OutlineTree.containingEntryIndex(in:caretOffset:)`. Called by
    /// `EditorViewController` on its own, separate debounce (caret movement is far more frequent
    /// than an edit — see `EditorViewController.onCaretDidMove`).
    ///
    /// A caret before the first heading, or a document with none, clears the selection rather than
    /// leaving a stale row highlighted.
    func highlightEntry(containingCaret caretOffset: Int) {
        guard
            let entryIndex = OutlineTree.containingEntryIndex(in: currentEntries, caretOffset: caretOffset),
            let row = rowsByEntryIndex[entryIndex]
        else {
            guard outlineView.selectedRow >= 0 else { return }
            isApplyingProgrammaticSelection = true
            outlineView.deselectAll(nil)
            isApplyingProgrammaticSelection = false
            return
        }

        let targetRow = outlineView.row(forItem: row)
        // `-1` means the row is inside a currently-collapsed section — nothing visible to select.
        guard targetRow >= 0, outlineView.selectedRow != targetRow else { return }
        isApplyingProgrammaticSelection = true
        outlineView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        isApplyingProgrammaticSelection = false
    }

    private static func font(forLevel level: Int) -> NSFont {
        switch level {
        case 1: return .systemFont(ofSize: 13, weight: .semibold)
        case 2: return .systemFont(ofSize: 12, weight: .medium)
        default: return .systemFont(ofSize: 11, weight: .regular)
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension OutlineViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Row)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Row)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Row)?.children.isEmpty ?? true)
    }
}

// MARK: - NSOutlineViewDelegate

extension OutlineViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? Row else { return nil }

        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: Self.rowCellIdentifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = Self.rowCellIdentifier
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let title = row.entry.title.isEmpty ? "Untitled" : row.entry.title
        cell.textField?.stringValue = title
        cell.textField?.font = Self.font(forLevel: row.entry.level)
        // VoiceOver needs both the title and the heading level announced — the visual indentation
        // and font-size scaling that convey level to a sighted user convey nothing on their own to
        // a screen reader.
        cell.setAccessibilityLabel("\(title), heading level \(row.entry.level)")
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingProgrammaticSelection else { return }
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0, let row = outlineView.item(atRow: selectedRow) as? Row else { return }
        onSelectEntry?(row.entry)
    }
}
