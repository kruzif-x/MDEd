/// The kind of Markdown construct a `SyntaxElement` describes, carrying whatever per-kind data a
/// live-preview or styled-source renderer needs to decide how to draw it.
public enum SyntaxKind: Sendable, Equatable, Hashable {
    /// An ATX heading (`# ` through `###### `). `level` is 1–6.
    case heading(level: Int)
    /// `*emphasis*` or `_emphasis_`.
    case emphasis
    /// `**strong**` or `__strong__`.
    case strong
    /// `~~strikethrough~~`.
    case strikethrough
    /// `` `inline code` ``.
    case inlineCode
    /// A fenced or indented code block. `language` is the fence's info string, if any
    /// (e.g. `swift` in ` ```swift `), `nil` for an indented block or a fence with no info string.
    case codeBlock(language: String?)
    /// A fenced code block whose info string is exactly `mermaid` — reported as its own kind
    /// (distinct from a generic `codeBlock`) since a live-preview layer renders it as a diagram,
    /// not as highlighted source.
    case diagramBlock
    /// `$inline math$` — not part of CommonMark; detected by MDEdCore's own scan of raw text,
    /// see `SyntaxMapper`.
    case inlineMath
    /// `$$display math$$` — likewise not part of CommonMark.
    case displayMath
    /// `[link text](destination "title")` or a reference-style link. `destination` is `nil` for
    /// an unresolved reference link.
    case link(destination: String?)
    /// `![alt text](destination "title")`.
    case image(destination: String?)
    /// One item of an ordered or unordered list, including its marker (`-`, `*`, `+`, `1.`, `1)`,
    /// and an optional task-list checkbox `[ ]`/`[x]`).
    case listItem
    /// A `> ` block quote. Because the marker repeats on every line of the quote, this kind's
    /// `markerRanges` (see `SyntaxElement`) contains one range per line rather than one.
    case blockQuote
    /// A `---`/`***`/`___` thematic break. Has no distinct content — the whole element is marker.
    case thematicBreak
    /// A GitHub-Flavored-Markdown pipe table.
    case table
}
