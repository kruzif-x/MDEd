import Cocoa
import SwiftUI

/// Builds the entire main menu in code (no MainMenu.xib), so the project stays generatable from
/// `project.yml` and the menu structure is reviewable as a plain diff.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Lazily created on first ⌘, and reused — a Settings panel is a singleton by convention.
    private var settingsWindowController: NSWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        EditorSettings.registerDefaults()
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        // Applied once at launch; live theme changes afterward are handled by the
        // `UserDefaults.didChangeNotification` observer below (and independently by every open
        // `EditorViewController`, for font/measure/spacing).
        EditorSettings.current().applyTheme()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            EditorSettings.current().applyTheme()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Avoids a "state restoration" console warning on modern macOS; not a compiler warning, just
    // good citizenship for a document-based app with no interest in secure restorable state yet.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu construction

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        main.addItem(withSubmenu: appMenu())
        main.addItem(withSubmenu: fileMenu())
        main.addItem(withSubmenu: editMenu())
        main.addItem(withSubmenu: viewMenu())
        main.addItem(withSubmenu: formatMenu())
        main.addItem(withSubmenu: aiMenu())
        main.addItem(withSubmenu: windowMenu())

        return main
    }

    private func appMenu() -> NSMenu {
        let appName = "MDEd"
        let menu = NSMenu(title: appName)

        menu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")

        menu.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        menu.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        // `saveDocument:`/`saveDocumentAs:`/`revertDocumentToSaved:` are `NSDocument` responder-
        // chain actions with no directly callable Swift declaration to point `#selector` at (their
        // Swift-side names are compiler-internal). `NSSelectorFromString` builds the exact,
        // stable Objective-C selector AppKit has used since NSDocument's inception; target stays
        // nil so it resolves against whichever document is currently active.
        menu.addItem(withTitle: "Save…", action: NSSelectorFromString("saveDocument:"), keyEquivalent: "s")
        menu.addItem(withTitle: "Save As…", action: NSSelectorFromString("saveDocumentAs:"), keyEquivalent: "S")
        menu.addItem(withTitle: "Revert to Saved", action: NSSelectorFromString("revertDocumentToSaved:"), keyEquivalent: "")
        menu.addItem(.separator())
        // Target is this delegate (not `nil`/responder-chain) since neither action depends on
        // which document window is key — "Compare Two Files…" doesn't need one at all, and
        // "Compare Frontmost With…" looks the frontmost document up itself via
        // `NSDocumentController.currentDocument`.
        let compareTwo = menu.addItem(withTitle: "Compare Two Files…", action: #selector(compareTwoFiles(_:)), keyEquivalent: "c")
        compareTwo.keyEquivalentModifierMask = [.command, .shift]
        compareTwo.target = self
        let compareFrontmost = menu.addItem(withTitle: "Compare Frontmost With…", action: #selector(compareFrontmostDocument(_:)), keyEquivalent: "")
        compareFrontmost.target = self

        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")

        // `undo:`/`redo:` aren't declared on any public Swift-visible type at all — AppKit wires
        // them to `NSUndoManager` via a private responder-chain mechanism — so `NSSelectorFromString`
        // is the only way to reference them.
        menu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withSubmenu: findMenu())

        return menu
    }

    /// Wires ⌘F (and friends) to `NSTextView`'s built-in find bar — enabled on the text view via
    /// `usesFindBar = true` / `isIncrementalSearchingEnabled = true`. The tag on each item matches
    /// `NSTextFinder.Action`, which `performTextFinderAction(_:)` inspects.
    private func findMenu() -> NSMenu {
        let menu = NSMenu(title: "Find")

        func addFinderAction(_ title: String, _ action: NSTextFinder.Action, _ key: String, modifiers: NSEvent.ModifierFlags = [.command]) {
            let item = menu.addItem(withTitle: title, action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = action.rawValue
        }

        addFinderAction("Find…", .showFindInterface, "f")
        addFinderAction("Find Next", .nextMatch, "g")
        addFinderAction("Find Previous", .previousMatch, "g", modifiers: [.command, .shift])
        addFinderAction("Use Selection for Find", .setSearchString, "e")

        return menu
    }

    /// A single live-preview toggle, reachable without opening Settings — see
    /// `EditorSettings.livePreviewEnabled`'s doc comment for why this exists as a menu command
    /// (and not only a Settings checkbox): the owner reaches for it during normal writing, not just
    /// once at setup. The item's title never changes (`toggleLiveMarkerHiding(_:)` always says
    /// "Hide Markdown Syntax"); its checkmark state is what communicates on/off, driven fresh from
    /// `EditorSettings.current()` on every menu validation pass — see this file's
    /// `NSMenuItemValidation` conformance below — so flipping the value from *either* this menu
    /// item or the Settings toggle immediately shows up correctly in the other, with no explicit
    /// sync step: both read and write the exact same `UserDefaults` key.
    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        let item = menu.addItem(withTitle: "Hide Markdown Syntax", action: #selector(toggleLiveMarkerHiding(_:)), keyEquivalent: "/")
        item.target = self
        return menu
    }

    @objc func toggleLiveMarkerHiding(_ sender: Any?) {
        var settings = EditorSettings.current()
        settings.livePreviewEnabled.toggle()
        UserDefaults.standard.set(settings.livePreviewEnabled, forKey: EditorSettings.Keys.livePreviewEnabled)
    }

    /// Deterministic, non-AI Markdown commands — see `TableOfContents`/`MarkdownFormatting` for why
    /// these are plain functions rather than model calls. Every item routes through the responder
    /// chain (`target = nil`) to whichever `EditorViewController` is key, exactly like the toolbar's
    /// formatting buttons.
    private func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        let toc = menu.addItem(withTitle: "Insert Table of Contents", action: #selector(EditorViewController.insertTableOfContents(_:)), keyEquivalent: "")
        toc.target = nil
        let normalize = menu.addItem(withTitle: "Normalize Formatting", action: #selector(EditorViewController.normalizeFormatting(_:)), keyEquivalent: "")
        normalize.target = nil
        return menu
    }

    /// On-device AI commands (Stage 4) — see `AIService`'s doc comment for why FoundationModels is
    /// the only backend and there's no configuration surface here. `aiMenuDelegate` keeps the
    /// top diagnostic item's text and visibility current every time this menu opens; every actual
    /// command item is validated per-invocation by `EditorViewController.validateMenuItem(_:)`.
    private func aiMenu() -> NSMenu {
        let menu = NSMenu(title: "AI")
        menu.delegate = Self.aiMenuDelegate

        let diagnostic = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        diagnostic.isEnabled = false
        diagnostic.tag = Self.aiDiagnosticItemTag
        menu.addItem(diagnostic)
        menu.addItem(.separator())

        let summarize = menu.addItem(withTitle: "Summarize Document", action: #selector(EditorViewController.aiSummarizeDocument(_:)), keyEquivalent: "")
        summarize.target = nil
        let tighten = menu.addItem(withTitle: "Tighten Selection", action: #selector(EditorViewController.aiTightenSelection(_:)), keyEquivalent: "")
        tighten.target = nil
        menu.addItem(.separator())

        menu.addItem(withSubmenu: translateSubmenu(title: "Translate Selection", action: #selector(EditorViewController.aiTranslateSelection(_:))))
        menu.addItem(withSubmenu: translateSubmenu(title: "Translate Document", action: #selector(EditorViewController.aiTranslateDocument(_:))))

        return menu
    }

    private func translateSubmenu(title: String, action: Selector) -> NSMenu {
        let menu = NSMenu(title: title)
        for language in AILanguages.common {
            let item = menu.addItem(withTitle: language, action: action, keyEquivalent: "")
            item.target = nil
            item.representedObject = language
        }
        return menu
    }

    fileprivate static let aiDiagnosticItemTag = 9001
    /// Kept alive for the process lifetime as the AI menu's delegate (`NSMenu.delegate` is weak),
    /// same pattern `DocumentWindowController.toolbarDelegate` already uses for the same reason.
    private static let aiMenuDelegate = AIMenuDelegate()

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")

        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        NSApp.windowsMenu = menu
        return menu
    }

    // MARK: - Settings

    /// Not a literal SwiftUI `Settings` scene: this app deliberately keeps AppKit's manual
    /// `NSApplication` lifecycle (custom `main.swift`, no `@main App`/`DocumentGroup`) so its
    /// `NSDocument`-based windowing, tabs, and autosave — all tested and working — stay untouched.
    /// Adopting `Settings { }` would mean moving the entry point to a SwiftUI `App` conformance,
    /// which is an unnecessary risk to that working lifecycle for a panel that only needs to be a
    /// SwiftUI view reachable by ⌘,. This gets the same result: a real SwiftUI view, a real ⌘,
    /// shortcut, `@AppStorage` persistence, singleton reuse.
    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindowController = NSWindowController(window: window)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Comparison

    @objc func compareTwoFiles(_ sender: Any?) {
        CompareCoordinator.presentCompareTwoFiles()
    }

    @objc func compareFrontmostDocument(_ sender: Any?) {
        CompareCoordinator.presentCompareFrontmostDocument()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(compareFrontmostDocument(_:)) {
            return NSDocumentController.shared.currentDocument != nil
        }
        if menuItem.action == #selector(toggleLiveMarkerHiding(_:)) {
            menuItem.state = EditorSettings.current().livePreviewEnabled ? .on : .off
        }
        return true
    }
}

/// Updates the AI menu's top diagnostic item every time the menu opens: hidden when on-device AI
/// is available, otherwise showing `AIAvailability.unavailable`'s own explanation of what's true
/// and (where there's something to do about it) what the user would need to do. A plain `NSObject`
/// (not `AppDelegate` itself), same reasoning `DocumentWindowController.ToolbarDelegate` documents:
/// this only needs three lines of logic and no access to anything else on `AppDelegate`.
private final class AIMenuDelegate: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard let diagnostic = menu.item(withTag: AppDelegate.aiDiagnosticItemTag) else { return }
        switch AIServiceProvider.shared.availability {
        case .available:
            diagnostic.isHidden = true
        case .unavailable(let explanation):
            diagnostic.title = explanation
            diagnostic.isHidden = false
        }
    }
}

private extension NSMenu {
    /// Adds `submenu` as a new top-level item titled after the submenu, mirroring the
    /// `NSMenuItem(title:action:keyEquivalent:)` + `.submenu = ` pattern the rest of this file uses.
    func addItem(withSubmenu submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
