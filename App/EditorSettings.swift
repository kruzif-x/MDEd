import Cocoa

/// The user-tunable knobs from the Settings panel (⌘,), backed by `UserDefaults` so both the
/// SwiftUI settings UI (`@AppStorage`) and the plain-AppKit editor read/write the same store.
///
/// `EditorSettings` itself is a plain, `Sendable` snapshot — no observation machinery of its own.
/// AppKit call sites (`EditorViewController`, `MarkdownStyler`) read a fresh snapshot via
/// `EditorSettings.current()` whenever `UserDefaults.didChangeNotification` fires, which is how a
/// live change in the Settings window reaches every open document window, not just new ones.
struct EditorSettings: Sendable, Equatable {

    enum FontFamily: String, Sendable, CaseIterable, Identifiable {
        case monospaced
        case proportional
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .monospaced: return "Monospaced"
            case .proportional: return "Proportional"
            }
        }
    }

    enum Theme: String, Sendable, CaseIterable, Identifiable {
        case system
        case light
        case dark
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    var fontFamily: FontFamily
    /// Family name for the monospaced face (a `PostScript`/family name resolvable via `NSFont`).
    var monospacedFontName: String
    /// Family name for the proportional face.
    var proportionalFontName: String
    var fontSize: Double
    /// The measure, in columns (monospaced character widths) rather than points — so the
    /// typographic intent (how many characters fit on a line) stays stable across font-size
    /// changes. Canonical hard-wrapped Markdown is 80 columns; the default of 88 stays clear of
    /// that so ordinary hard-wrapped source never double-wraps. See
    /// `EditorSettings.measureWidthPoints(font:)` for how this becomes an actual container width.
    var measureColumns: Double
    /// Extra spacing (points) layered on top of the base line height, between adjacent lines.
    var lineSpacing: Double
    /// Base unit (points) for block-level vertical rhythm: the gap after an ordinary paragraph,
    /// and the scale headings' extra before/after air is derived from — see
    /// `MarkdownStyler.applyHeadingRhythm`.
    var paragraphSpacing: Double
    var theme: Theme
    /// Shows a source-line-number gutter (`LineNumberGutterView`) on the editor's and each compare
    /// pane's scroll view. On by default — see `EditorSettings.default` for why.
    var showLineNumbers: Bool

    /// Live-preview editing: Markdown markers (`##`, `**`, `` ` ``, `>`, list bullets, …) hide
    /// except on the cursor's current line, and tables/math/Mermaid render inline as images except
    /// where the cursor is. On by default (that's the point of the feature), but
    /// this is the escape hatch — turn it off to fall back to plain styled source (today's
    /// behavior: every marker visible and dimmed, nothing rendered) if hiding proves more
    /// distracting than helpful. Toggled from Settings *or* View ▸ Hide Markdown Syntax (⌘/) — see
    /// `AppDelegate.toggleLiveMarkerHiding(_:)`; both read and write this same key, so they can
    /// never drift out of sync with each other.
    var livePreviewEnabled: Bool

    /// The font actually in use given the current family choice.
    var activeFontName: String {
        fontFamily == .monospaced ? monospacedFontName : proportionalFontName
    }

    static let `default` = EditorSettings(
        fontFamily: .monospaced,
        monospacedFontName: "SF Mono",
        proportionalFontName: "New York",
        fontSize: 13,
        measureColumns: 88,
        lineSpacing: 4,
        paragraphSpacing: 6,
        theme: .system,
        showLineNumbers: true,
        livePreviewEnabled: true
    )

    // MARK: - UserDefaults bridge

    enum Keys {
        static let fontFamily = "editor.fontFamily"
        static let monospacedFontName = "editor.monospacedFontName"
        static let proportionalFontName = "editor.proportionalFontName"
        static let fontSize = "editor.fontSize"
        static let measureColumns = "editor.measureColumns"
        static let lineSpacing = "editor.lineSpacing"
        static let paragraphSpacing = "editor.paragraphSpacing"
        static let theme = "editor.theme"
        static let showLineNumbers = "editor.showLineNumbers"
        static let livePreviewEnabled = "editor.livePreviewEnabled"
    }

    /// Registers factory defaults. Call once, early (from `AppDelegate`), so every `UserDefaults`
    /// read — including the very first `@AppStorage` access in SwiftUI — sees a real value instead
    /// of a type-default zero/empty string.
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Keys.fontFamily: EditorSettings.default.fontFamily.rawValue,
            Keys.monospacedFontName: EditorSettings.default.monospacedFontName,
            Keys.proportionalFontName: EditorSettings.default.proportionalFontName,
            Keys.fontSize: EditorSettings.default.fontSize,
            Keys.measureColumns: EditorSettings.default.measureColumns,
            Keys.lineSpacing: EditorSettings.default.lineSpacing,
            Keys.paragraphSpacing: EditorSettings.default.paragraphSpacing,
            Keys.theme: EditorSettings.default.theme.rawValue,
            Keys.showLineNumbers: EditorSettings.default.showLineNumbers,
            Keys.livePreviewEnabled: EditorSettings.default.livePreviewEnabled,
        ])
    }

    /// A fresh snapshot of the current settings. Cheap enough to call on every
    /// `UserDefaults.didChangeNotification` — there is no caching to invalidate.
    static func current(from defaults: UserDefaults = .standard) -> EditorSettings {
        EditorSettings(
            fontFamily: FontFamily(rawValue: defaults.string(forKey: Keys.fontFamily) ?? "") ?? .monospaced,
            monospacedFontName: defaults.string(forKey: Keys.monospacedFontName) ?? EditorSettings.default.monospacedFontName,
            proportionalFontName: defaults.string(forKey: Keys.proportionalFontName) ?? EditorSettings.default.proportionalFontName,
            fontSize: defaults.double(forKey: Keys.fontSize) == 0 ? EditorSettings.default.fontSize : defaults.double(forKey: Keys.fontSize),
            measureColumns: defaults.double(forKey: Keys.measureColumns) == 0 ? EditorSettings.default.measureColumns : defaults.double(forKey: Keys.measureColumns),
            lineSpacing: defaults.object(forKey: Keys.lineSpacing) == nil ? EditorSettings.default.lineSpacing : defaults.double(forKey: Keys.lineSpacing),
            paragraphSpacing: defaults.object(forKey: Keys.paragraphSpacing) == nil ? EditorSettings.default.paragraphSpacing : defaults.double(forKey: Keys.paragraphSpacing),
            theme: Theme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system,
            showLineNumbers: defaults.object(forKey: Keys.showLineNumbers) == nil ? EditorSettings.default.showLineNumbers : defaults.bool(forKey: Keys.showLineNumbers),
            livePreviewEnabled: defaults.object(forKey: Keys.livePreviewEnabled) == nil ? EditorSettings.default.livePreviewEnabled : defaults.bool(forKey: Keys.livePreviewEnabled)
        )
    }

    /// Derives the text-container width, in points, that `measureColumns` corresponds to for
    /// `font`. Uses the advance width of the glyph "0" as the per-column width: exact for a
    /// monospaced font (every glyph shares that advance), and a reasonable stand-in for a
    /// proportional font's average character width otherwise.
    func measureWidthPoints(font: NSFont) -> CGFloat {
        let columnWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        return CGFloat(measureColumns) * columnWidth
    }

    /// Applies `theme` to the whole app. Called once at launch and again on every settings change
    /// — idempotent, so there's no harm re-applying the same value.
    func applyTheme() {
        switch theme {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
