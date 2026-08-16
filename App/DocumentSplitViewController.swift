import Cocoa

/// The document window's root view controller: a leading-edge, collapsible outline sidebar plus the
/// editor, composed with `NSSplitViewController` so the sidebar gets the conventional macOS
/// structure — `.sidebar` material, standard collapse/expand animation, and (via the `.toggleSidebar`
/// toolbar identifier `DocumentWindowController` adds) the system sidebar-toggle button — without
/// this app reimplementing any of it.
///
/// Scoped to the ordinary document window only. The comparison window already shows two panes plus
/// its own hunk navigation; a third and fourth pane (two outlines) would be too cramped to be worth
/// it — see `App/Compare`'s own note and the top-level README.
final class DocumentSplitViewController: NSSplitViewController {

    /// The sidebar's default width for a first-ever launch (before any frame-autosave/divider
    /// position exists) — `DocumentWindowController.defaultContentSize()` adds this to the window's
    /// default width so the editor's own measure isn't cramped by the sidebar's default appearance.
    static let defaultSidebarWidth: CGFloat = 220

    let outlineViewController: OutlineViewController
    let editorViewController: EditorViewController

    private let sidebarItem: NSSplitViewItem
    private var settingsObserver: NSObjectProtocol?
    private var collapseObservation: NSKeyValueObservation?
    /// Guards `applySidebarSettingIfNeeded()`'s write to `sidebarItem.isCollapsed` from re-entering
    /// `sidebarCollapseDidChange` as if it were a fresh user toggle — same guard shape
    /// `EditorViewController.applyCurrentSettings` uses via `lastAppliedSettings`.
    private var isApplyingExternalCollapseChange = false

    init(document: Document) {
        editorViewController = EditorViewController(document: document)
        outlineViewController = OutlineViewController()

        sidebarItem = NSSplitViewItem(sidebarWithViewController: outlineViewController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !EditorSettings.current().showOutlineSidebar

        let contentItem = NSSplitViewItem(viewController: editorViewController)

        super.init(nibName: nil, bundle: nil)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        splitView.dividerStyle = .thin

        wireOutline()
        observeSettingsChanges()
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            self?.sidebarCollapseDidChange(isCollapsed: item.isCollapsed)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — this app has no storyboard/xib")
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    /// Bridges the editor's text/caret changes to the outline, and the outline's row selection back
    /// to the editor — both closures the two view controllers wire against each other, kept here
    /// rather than in either of them so neither needs a direct reference to the other.
    private func wireOutline() {
        editorViewController.onOutlineTextDidChange = { [weak self] text in
            self?.outlineViewController.update(text: text)
        }
        editorViewController.onCaretDidMove = { [weak self] caretOffset in
            self?.outlineViewController.highlightEntry(containingCaret: caretOffset)
        }
        outlineViewController.onSelectEntry = { [weak self] entry in
            self?.editorViewController.revealAndPlaceCaret(at: entry.range)
        }
    }

    // MARK: - Sidebar state ⇄ EditorSettings

    /// A real user toggle (the toolbar button, the View menu item, ⌥⌘S, or dragging/double-clicking
    /// the divider — all of them ultimately flip `NSSplitViewItem.isCollapsed`) — write it back into
    /// `EditorSettings` so every other open document window's sidebar follows, and the choice is
    /// remembered at next launch. Skipped while `applySidebarSettingIfNeeded()` is itself the one
    /// setting `isCollapsed`, so the two directions don't ping-pong.
    private func sidebarCollapseDidChange(isCollapsed: Bool) {
        guard !isApplyingExternalCollapseChange else { return }
        let shouldShow = !isCollapsed
        guard EditorSettings.current().showOutlineSidebar != shouldShow else { return }
        UserDefaults.standard.set(shouldShow, forKey: EditorSettings.Keys.showOutlineSidebar)
    }

    private func observeSettingsChanges() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applySidebarSettingIfNeeded()
        }
    }

    /// Mirrors `EditorSettings.showOutlineSidebar` onto this window's sidebar — the other half of
    /// `sidebarCollapseDidChange`'s write, so a toggle made in *any* document window's toolbar/menu
    /// reaches every other one immediately, matching how every other live setting in this app works.
    /// Goes through `.animator()` so the View-menu/⌥⌘S path (which, unlike the toolbar's native
    /// `.toggleSidebar` button, has no built-in collapse animation of its own — see
    /// `AppDelegate.toggleOutlineSidebar(_:)`) still animates instead of snapping.
    private func applySidebarSettingIfNeeded() {
        let shouldShow = EditorSettings.current().showOutlineSidebar
        guard sidebarItem.isCollapsed == shouldShow else { return }
        isApplyingExternalCollapseChange = true
        sidebarItem.animator().isCollapsed = !shouldShow
        isApplyingExternalCollapseChange = false
    }
}
