import Cocoa
import MDEdCore

/// Drives an `NSTextStorage`'s attributes from `MDEdCore.syntaxMap(of:)`.
///
/// This is "styled source", not live preview: syntax markers (`##`, `**`, `` ` ``, …) always stay
/// in the text, just dimmed via `secondaryLabelColor`/`tertiaryLabelColor`, while the content they
/// wrap gets the actual styling (bold, italic, size, color, background). Every method here only
/// ever calls `addAttribute`/`setAttributes` on the given `NSTextStorage` — never
/// `replaceCharacters` — so restyling never disturbs the text view's undo stack or the caret
/// position; callers are expected to wrap the whole pass in `beginEditing()`/`endEditing()`.
enum MarkdownStyler {

    /// The editor's body font. Monospaced (see `EditorViewController` for the rationale) — sizes
    /// below are all derived from this so headings scale relative to it.
    static func baseFont(size: CGFloat = 13) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Re-parses `textStorage.string` and reapplies every attribute from scratch. Safe to call as
    /// often as needed (e.g. from a debounced timer) — `syntaxMap(of:)` is a pure, stateless
    /// function with no incremental state to keep in sync.
    static func restyle(_ textStorage: NSTextStorage) {
        let source = textStorage.string
        let elements = syntaxMap(of: source)
        let full = NSRange(location: 0, length: textStorage.length)
        guard full.length > 0 else { return }

        textStorage.beginEditing()

        // Reset to a clean baseline first: `setAttributes(_:range:)` *replaces* the attribute
        // dictionary for the range rather than merging into it, so any styling left over from a
        // construct that no longer parses (e.g. the user deleted a closing "**") is cleared before
        // the fresh pass below re-adds only what still applies.
        textStorage.setAttributes(
            [.font: baseFont(), .foregroundColor: NSColor.labelColor],
            range: full
        )

        // Parents before children, so a heading's size/weight is established before an emphasis
        // or strong span nested inside it layers its own trait on top.
        for element in elements.sorted(by: { $0.depth != $1.depth ? $0.depth < $1.depth : $0.range.lowerBound < $1.range.lowerBound }) {
            apply(element, to: textStorage, docLength: textStorage.length)
        }

        textStorage.endEditing()
    }

    // MARK: - Per-kind styling

    private static func apply(_ element: SyntaxElement, to textStorage: NSTextStorage, docLength: Int) {
        func clamp(_ range: MDEdCore.TextRange) -> NSRange? {
            let r = range.nsRange
            guard r.location >= 0, r.length >= 0, r.location + r.length <= docLength else { return nil }
            return r
        }

        func dimMarkers(_ color: NSColor = .secondaryLabelColor) {
            for marker in element.markerRanges {
                guard let r = clamp(marker), r.length > 0 else { continue }
                textStorage.addAttribute(.foregroundColor, value: color, range: r)
            }
        }

        func fontAt(_ location: Int) -> NSFont {
            guard location < docLength,
                  let font = textStorage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
            else { return baseFont() }
            return font
        }

        func boldVariant(of font: NSFont) -> NSFont {
            .monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
        }

        switch element.kind {
        case .heading(let level):
            guard let full = clamp(element.range) else { return }
            let sizeByLevel: [CGFloat] = [22, 19, 17, 15.5, 14, 13]
            let size = sizeByLevel[min(max(level - 1, 0), sizeByLevel.count - 1)]
            textStorage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size, weight: .bold), range: full)
            dimMarkers()

        case .emphasis:
            if let content = element.contentRange, let r = clamp(content) {
                // SF Mono has no true italic member, so a font-trait conversion silently falls
                // back to upright. `.obliqueness` synthesizes a slant reliably on any font.
                textStorage.addAttribute(.obliqueness, value: 0.18, range: r)
            }
            dimMarkers()

        case .strong:
            if let content = element.contentRange, let r = clamp(content) {
                textStorage.addAttribute(.font, value: boldVariant(of: fontAt(r.location)), range: r)
            }
            dimMarkers()

        case .strikethrough:
            if let content = element.contentRange, let r = clamp(content) {
                textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                textStorage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
            }
            dimMarkers()

        case .inlineCode:
            if let full = clamp(element.range) {
                textStorage.addAttribute(.backgroundColor, value: NSColor.unemphasizedSelectedContentBackgroundColor, range: full)
            }
            dimMarkers()

        case .codeBlock, .diagramBlock:
            if let full = clamp(element.range) {
                textStorage.addAttribute(.backgroundColor, value: NSColor.unemphasizedSelectedContentBackgroundColor, range: full)
            }
            dimMarkers()

        case .inlineMath, .displayMath:
            if let full = clamp(element.range) {
                textStorage.addAttribute(.backgroundColor, value: NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.6), range: full)
            }
            dimMarkers()

        case .link, .image:
            if let content = element.contentRange, let r = clamp(content) {
                textStorage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: r)
                textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            }
            dimMarkers()

        case .listItem:
            for marker in element.markerRanges {
                guard let r = clamp(marker), r.length > 0 else { continue }
                textStorage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
                textStorage.addAttribute(.font, value: boldVariant(of: fontAt(r.location)), range: r)
            }

        case .blockQuote:
            if let content = element.contentRange, let r = clamp(content) {
                textStorage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
                textStorage.addAttribute(.obliqueness, value: 0.1, range: r)
            }
            for marker in element.markerRanges {
                guard let r = clamp(marker), r.length > 0 else { continue }
                textStorage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
                textStorage.addAttribute(.font, value: boldVariant(of: fontAt(r.location)), range: r)
            }

        case .thematicBreak:
            if let full = clamp(element.range) {
                textStorage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: full)
                textStorage.addAttribute(.font, value: boldVariant(of: fontAt(full.location)), range: full)
            }

        case .table:
            if let full = clamp(element.range) {
                textStorage.addAttribute(.backgroundColor, value: NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5), range: full)
            }
        }
    }
}
