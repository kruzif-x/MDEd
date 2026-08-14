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
///
/// Code blocks, tables, and block quotes do *not* get a `.backgroundColor` text attribute — that
/// makes the fill hug the glyphs (ragged line ends, blank lines inside a fence falling outside the
/// tint, detached patches around fences). Instead `restyle` returns a `[BlockDecoration]` list
/// that `MarkdownTextView` paints behind the line fragments in its own draw pass. Inline code is
/// the one exception: it stays a glyph-hugging `.backgroundColor` attribute, which is correct for
/// an inline span.
enum MarkdownStyler {

    /// The editor's body font, honoring the current family/size settings. Sizes elsewhere are all
    /// derived from this so headings scale relative to it.
    static func baseFont(_ settings: EditorSettings = .current()) -> NSFont {
        font(family: settings.fontFamily, name: settings.activeFontName, size: settings.fontSize)
    }

    /// Re-parses `textStorage.string` and reapplies every attribute from scratch. Safe to call as
    /// often as needed (e.g. from a debounced timer) — `syntaxMap(of:)` is a pure, stateless
    /// function with no incremental state to keep in sync.
    ///
    /// Returns the block-level decorations (code blocks, tables, block quotes) the caller should
    /// hand to `MarkdownTextView.blockDecorations` for behind-the-glyphs background painting.
    @discardableResult
    static func restyle(_ textStorage: NSTextStorage, settings: EditorSettings) -> [BlockDecoration] {
        let source = textStorage.string
        let elements = syntaxMap(of: source)
        let full = NSRange(location: 0, length: textStorage.length)
        guard full.length > 0 else { return [] }

        textStorage.beginEditing()

        // Reset to a clean baseline first: `setAttributes(_:range:)` *replaces* the attribute
        // dictionary for the range rather than merging into it, so any styling left over from a
        // construct that no longer parses (e.g. the user deleted a closing "**") is cleared before
        // the fresh pass below re-adds only what still applies.
        let baseParagraphStyle = makeParagraphStyle(lineSpacing: settings.lineSpacing, after: CGFloat(settings.paragraphSpacing))
        textStorage.setAttributes(
            [.font: baseFont(settings), .foregroundColor: NSColor.labelColor, .paragraphStyle: baseParagraphStyle],
            range: full
        )

        var decorations: [BlockDecoration] = []

        // Parents before children, so a heading's size/weight is established before an emphasis
        // or strong span nested inside it layers its own trait on top.
        for element in elements.sorted(by: { $0.depth != $1.depth ? $0.depth < $1.depth : $0.range.lowerBound < $1.range.lowerBound }) {
            apply(element, to: textStorage, docLength: textStorage.length, settings: settings, decorations: &decorations)
        }

        applyHeadingRhythm(elements, to: textStorage, docLength: textStorage.length, settings: settings)

        textStorage.endEditing()
        return decorations
    }

    // MARK: - Font resolution

    /// Resolves `name` (a font *family* name, e.g. from `NSFontManager.availableFontFamilies` or
    /// the `EditorSettings` defaults) to an actual `NSFont`, falling back to the system faces used
    /// before fonts became configurable if the named family isn't installed.
    private static func font(family: EditorSettings.FontFamily, name: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if let resolved = NSFontManager.shared.font(withFamily: name, traits: traits, weight: 5, size: size) {
            return resolved
        }
        switch family {
        case .monospaced:
            return .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        case .proportional:
            return bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        }
    }

    /// Always monospaced, regardless of `settings.fontFamily` — code keeps its alignment-sensitive
    /// shape (indentation, table-like output) even when the surrounding prose is proportional.
    /// Honors the user's chosen monospaced typeface/size, just not the family toggle.
    private static func monospaceFont(_ settings: EditorSettings) -> NSFont {
        font(family: .monospaced, name: settings.monospacedFontName, size: settings.fontSize)
    }

    private static func boldVariant(of font: NSFont, settings: EditorSettings) -> NSFont {
        let converted = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        if converted.fontDescriptor.symbolicTraits.contains(.bold) { return converted }
        switch settings.fontFamily {
        case .monospaced: return .monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
        case .proportional: return .boldSystemFont(ofSize: font.pointSize)
        }
    }

    /// A genuine italic face if the current font family has one, `nil` otherwise (e.g. SF Mono,
    /// which has no italic member — a font-trait conversion on it silently falls back to upright).
    private static func realItalicVariant(of font: NSFont) -> NSFont? {
        let converted = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        return converted.fontDescriptor.symbolicTraits.contains(.italic) ? converted : nil
    }

    // MARK: - Vertical rhythm

    private static func makeParagraphStyle(lineSpacing: CGFloat, before: CGFloat = 0, after: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        return style
    }

    /// Headings get breathing room above and below, proportional to level (`#` gets the most,
    /// `######` the least) — this is what makes a heading read as a section boundary rather than
    /// just bigger, bolder text sitting flush against its neighbors.
    ///
    /// The absolute point values scale with `settings.paragraphSpacing`, the user-tunable
    /// "Paragraph spacing" control: these ratio tables are calibrated against
    /// `EditorSettings.default.paragraphSpacing` (6pt), so at the default setting a level-1
    /// heading gets 14pt before / 8pt after, tapering down to 5pt / 3pt at level 6. Dragging the
    /// slider scales every level (and the base inter-paragraph gap set in `restyle`) together,
    /// rather than needing a separate control per heading level.
    private static let headingBeforeRatioByLevel: [CGFloat] = [14, 12, 10, 8.5, 7, 5]
    private static let headingAfterRatioByLevel: [CGFloat] = [8, 7, 6, 5, 4, 3]

    private static func applyHeadingRhythm(_ elements: [SyntaxElement], to textStorage: NSTextStorage, docLength: Int, settings: EditorSettings) {
        let scale = CGFloat(settings.paragraphSpacing) / CGFloat(EditorSettings.default.paragraphSpacing)
        let text = textStorage.string as NSString

        for element in elements {
            guard case .heading(let level) = element.kind else { continue }
            let r = element.range.nsRange
            guard r.location >= 0, r.length >= 0, r.location + r.length <= docLength else { continue }
            let idx = min(max(level - 1, 0), Self.headingBeforeRatioByLevel.count - 1)
            let paragraphRange = text.paragraphRange(for: r)
            let style = makeParagraphStyle(
                lineSpacing: settings.lineSpacing,
                before: Self.headingBeforeRatioByLevel[idx] * scale,
                after: Self.headingAfterRatioByLevel[idx] * scale
            )
            textStorage.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
        }
    }

    // MARK: - Per-kind styling

    private static func apply(_ element: SyntaxElement, to textStorage: NSTextStorage, docLength: Int, settings: EditorSettings, decorations: inout [BlockDecoration]) {
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
            else { return baseFont(settings) }
            return font
        }

        switch element.kind {
        case .heading(let level):
            guard let full = clamp(element.range) else { return }
            let sizeByLevel: [CGFloat] = [22, 19, 17, 15.5, 14, 13]
            let size = sizeByLevel[min(max(level - 1, 0), sizeByLevel.count - 1)]
            let headingBase = font(family: settings.fontFamily, name: settings.activeFontName, size: size, bold: true)
            textStorage.addAttribute(.font, value: headingBase, range: full)
            dimMarkers()

        case .emphasis:
            if let content = element.contentRange, let r = clamp(content) {
                if let italic = realItalicVariant(of: fontAt(r.location)) {
                    // A genuine italic face is available (typical for a proportional family) —
                    // use it instead of synthesizing a slant.
                    textStorage.addAttribute(.font, value: italic, range: r)
                } else {
                    // No italic member on this font (e.g. SF Mono) — `.obliqueness` synthesizes a
                    // slant reliably on any font.
                    textStorage.addAttribute(.obliqueness, value: 0.18, range: r)
                }
            }
            dimMarkers()

        case .strong:
            if let content = element.contentRange, let r = clamp(content) {
                textStorage.addAttribute(.font, value: boldVariant(of: fontAt(r.location), settings: settings), range: r)
            }
            dimMarkers()

        case .strikethrough:
            if let content = element.contentRange, let r = clamp(content) {
                textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                textStorage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
            }
            dimMarkers()

        case .inlineCode:
            // Inline code is the one construct that should keep a glyph-hugging background — it's
            // an inline span, not a block, so following the glyphs is exactly correct here.
            if let full = clamp(element.range) {
                textStorage.addAttribute(.backgroundColor, value: NSColor.unemphasizedSelectedContentBackgroundColor, range: full)
                // Code stays monospace even when the body is proportional — a proportional face
                // would misalign anything code-shaped (indentation, alignment-sensitive symbols).
                textStorage.addAttribute(.font, value: monospaceFont(settings), range: full)
            }
            dimMarkers()

        case .codeBlock, .diagramBlock:
            if let full = clamp(element.range) {
                decorations.append(BlockDecoration(range: full, kind: .code))
                textStorage.addAttribute(.font, value: monospaceFont(settings), range: full)
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
                textStorage.addAttribute(.font, value: boldVariant(of: fontAt(r.location), settings: settings), range: r)
            }

        case .blockQuote:
            if let content = element.contentRange, let r = clamp(content) {
                textStorage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
                textStorage.addAttribute(.obliqueness, value: 0.1, range: r)
            }
            for marker in element.markerRanges {
                guard let r = clamp(marker), r.length > 0 else { continue }
                textStorage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
                textStorage.addAttribute(.font, value: boldVariant(of: fontAt(r.location), settings: settings), range: r)
            }
            if let full = clamp(element.range) {
                decorations.append(BlockDecoration(range: full, kind: .quote))
            }

        case .thematicBreak:
            if let full = clamp(element.range) {
                textStorage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: full)
                textStorage.addAttribute(.font, value: boldVariant(of: fontAt(full.location), settings: settings), range: full)
            }

        case .table:
            if let full = clamp(element.range) {
                decorations.append(BlockDecoration(range: full, kind: .table))
            }
        }
    }
}
