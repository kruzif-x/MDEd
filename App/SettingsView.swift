import SwiftUI
import Cocoa

/// The ⌘, settings panel. Every control is backed by `@AppStorage`, so a change here lands in
/// `UserDefaults` immediately — `EditorViewController` picks it up via
/// `UserDefaults.didChangeNotification` and reapplies it to whatever document is currently open,
/// with no "Apply" button and no restart.
struct SettingsView: View {
    @AppStorage(EditorSettings.Keys.fontFamily) private var fontFamily = EditorSettings.default.fontFamily.rawValue
    @AppStorage(EditorSettings.Keys.monospacedFontName) private var monospacedFontName = EditorSettings.default.monospacedFontName
    @AppStorage(EditorSettings.Keys.proportionalFontName) private var proportionalFontName = EditorSettings.default.proportionalFontName
    @AppStorage(EditorSettings.Keys.fontSize) private var fontSize = EditorSettings.default.fontSize
    @AppStorage(EditorSettings.Keys.measureColumns) private var measureColumns = EditorSettings.default.measureColumns
    @AppStorage(EditorSettings.Keys.lineSpacing) private var lineSpacing = EditorSettings.default.lineSpacing
    @AppStorage(EditorSettings.Keys.paragraphSpacing) private var paragraphSpacing = EditorSettings.default.paragraphSpacing
    @AppStorage(EditorSettings.Keys.theme) private var theme = EditorSettings.default.theme.rawValue
    @AppStorage(EditorSettings.Keys.showLineNumbers) private var showLineNumbers = EditorSettings.default.showLineNumbers

    private var isMonospaced: Bool { fontFamily == EditorSettings.FontFamily.monospaced.rawValue }

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: $fontFamily) {
                    ForEach(EditorSettings.FontFamily.allCases) { family in
                        Text(family.displayName).tag(family.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(isMonospaced
                     ? "Keeps table pipes and list markers aligned in the source."
                     : "Reads better for prose; emphasis uses a real italic face.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isMonospaced {
                    Picker("Typeface", selection: $monospacedFontName) {
                        ForEach(FontCatalog.monospacedFamilies, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                } else {
                    Picker("Typeface", selection: $proportionalFontName) {
                        ForEach(FontCatalog.proportionalFamilies, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }

                LabeledContent("Size") {
                    Slider(value: $fontSize, in: 10...22, step: 0.5) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("10")
                    } maximumValueLabel: {
                        Text("22")
                    }
                }
                Text("\(fontSize, specifier: "%.1f") pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Layout") {
                LabeledContent("Measure") {
                    Slider(value: $measureColumns, in: 40...160, step: 2) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Narrow")
                    } maximumValueLabel: {
                        Text("Wide")
                    }
                }
                Text("\(Int(measureColumns)) columns — extra window width becomes margin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Line spacing") {
                    Slider(value: $lineSpacing, in: 0...14, step: 1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Tight")
                    } maximumValueLabel: {
                        Text("Airy")
                    }
                }

                LabeledContent("Paragraph spacing") {
                    Slider(value: $paragraphSpacing, in: 0...16, step: 1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Tight")
                    } maximumValueLabel: {
                        Text("Airy")
                    }
                }
                Text("Gap below paragraphs; headings scale from the same value.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Line Numbers", isOn: $showLineNumbers)
                Text("A quiet source-line gutter, in the editor and in comparison panes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(EditorSettings.Theme.allCases) { t in
                        Text(t.displayName).tag(t.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 640)
    }
}

/// Installed font families, split by fixed-pitch so the family picker in `SettingsView` only ever
/// offers faces that make sense for the family kind currently selected.
enum FontCatalog {
    static let monospacedFamilies: [String] = {
        let families = NSFontManager.shared.availableFontFamilies.filter { family in
            NSFont(name: family, size: 12)?.isFixedPitch == true
        }
        let preferred = ["SF Mono", "Menlo", "Monaco"]
        return (preferred.filter(families.contains) + families.filter { !preferred.contains($0) }.sorted())
    }()

    static let proportionalFamilies: [String] = {
        let families = NSFontManager.shared.availableFontFamilies.filter { family in
            NSFont(name: family, size: 12)?.isFixedPitch == false
        }
        let preferred = ["New York", "Helvetica Neue", "Georgia", "Avenir"]
        return (preferred.filter(families.contains) + families.filter { !preferred.contains($0) }.sorted())
    }()
}

#Preview {
    SettingsView()
}
