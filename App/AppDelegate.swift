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
