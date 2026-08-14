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
    /// Maximum text-container width in points — the "measure".
    var measureWidth: Double
    /// Extra spacing (points) layered on top of the base line height, between adjacent lines.
    var lineSpacing: Double
    var theme: Theme

    /// The font actually in use given the current family choice.
    var activeFontName: String {
        fontFamily == .monospaced ? monospacedFontName : proportionalFontName
    }

    static let `default` = EditorSettings(
        fontFamily: .monospaced,
        monospacedFontName: "SF Mono",
        proportionalFontName: "New York",
        fontSize: 13,
        measureWidth: 700,
        lineSpacing: 4,
        theme: .system
    )

    // MARK: - UserDefaults bridge

    enum Keys {
        static let fontFamily = "editor.fontFamily"
        static let monospacedFontName = "editor.monospacedFontName"
        static let proportionalFontName = "editor.proportionalFontName"
        static let fontSize = "editor.fontSize"
        static let measureWidth = "editor.measureWidth"
        static let lineSpacing = "editor.lineSpacing"
        static let theme = "editor.theme"
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
            Keys.measureWidth: EditorSettings.default.measureWidth,
            Keys.lineSpacing: EditorSettings.default.lineSpacing,
            Keys.theme: EditorSettings.default.theme.rawValue,
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
            measureWidth: defaults.double(forKey: Keys.measureWidth) == 0 ? EditorSettings.default.measureWidth : defaults.double(forKey: Keys.measureWidth),
            lineSpacing: defaults.object(forKey: Keys.lineSpacing) == nil ? EditorSettings.default.lineSpacing : defaults.double(forKey: Keys.lineSpacing),
            theme: Theme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        )
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
