/// One Markdown construct found in a source document, with its range split into the literal
/// syntax markers (`##`, `**`, `` ` ``, `> `, …) versus the content they wrap.
///
/// This split is the entire reason this module exists. A live-preview editor hides exactly the
/// marker ranges when the cursor isn't on that line and shows them when it is; a styled-source
/// renderer might dim markers and style content. Neither is implementable from `range` alone —
/// `range` covers marker *and* content together, e.g. for `**bold**` it spans all nine
/// characters, not just `bold`.
///
/// All ranges are `TextRange` (UTF-16 offsets into the original source string), directly usable
/// as `NSRange` via `TextRange.nsRange` — see `TextRange`'s documentation for why UTF-16 is the
/// unit that matters here.
public struct SyntaxElement: Sendable, Equatable {
    /// What kind of Markdown construct this is, with kind-specific data (heading level, code
    /// block language, link destination, …).
    public let kind: SyntaxKind

    /// The full range of this element in the source, markers and content together.
    public let range: TextRange

    /// The range of this element's content, i.e. `range` with the markers subtracted from each
    /// end. `nil` for elements with no distinct content of their own — currently only
    /// `.thematicBreak`, whose entire range is marker.
    public let contentRange: TextRange?

    /// The ranges of literal Markdown syntax that a live-preview layer should hide when the
    /// cursor is elsewhere. Usually one (a leading marker with no closing counterpart, e.g. a
    /// heading's `## `) or two (an opening and closing pair, e.g. `**`/`**`), but a `.blockQuote`
    /// contributes one range per line since its `> ` marker repeats on every line of the quote.
    /// Always disjoint from `contentRange` and, together with it, exactly reconstructs `range`.
    public let markerRanges: [TextRange]

    /// Nesting depth from the document root (the `Document` node itself is depth 0, its direct
    /// children depth 1, and so on). Lets a renderer answer "is this heading nested inside a
    /// block quote or list item" without re-walking the tree.
    public let depth: Int

    public init(kind: SyntaxKind, range: TextRange, contentRange: TextRange?, markerRanges: [TextRange], depth: Int) {
        self.kind = kind
        self.range = range
        self.contentRange = contentRange
        self.markerRanges = markerRanges
        self.depth = depth
    }
}
