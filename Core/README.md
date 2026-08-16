# MDEdCore

`MDEdCore` is the pure-logic core of **[MDEd](../README.md)**, a macOS Markdown editor. It has no
UI, no AppKit/SwiftUI, and no file I/O — just the three engines a Markdown editor with live-preview
editing and two-pane diffing is built on top of. The app target (`App/`, see the top-level README)
is everything AppKit on top of this.

## Modules

### `Diff` — line-level diffing between two Markdown documents

Built on the standard library's `CollectionDifference` (`Array.difference(from:)`) — no custom
Myers implementation, no dependency for this.

- `diffLines(_:_:) -> LineDiffResult` — diffs two `[String]` line arrays into `.unchanged`,
  `.removed`, `.inserted`, and `.changed` entries. `.changed` is MDEdCore's own addition on top
  of `CollectionDifference`, which only ever reports removals and insertions: a removal
  immediately followed by an insertion at the same edit-script position is paired off as one
  `.changed` line instead of two unrelated operations.
- `hunks(in:) -> [Hunk]` — groups contiguous runs of non-unchanged entries, each with its line
  ranges on both sides. This is what "jump to next change" and "take left"/"take right" operate
  on.
- `LineAlignmentMap` — the piece a scroll-sync implementation consumes. Given a (possibly
  fractional) line position in one document, returns the corresponding fractional position in the
  other, so two panes of different lengths can stay visually aligned as the user scrolls either
  one. Built from the diff's `.unchanged`/`.changed` entries as anchor points, with linear
  interpolation between them (and extrapolation from the document boundaries before the first
  anchor / after the last). Works in both directions.
- `diffWords(_:_:) -> WordDiffResult` — word/token-level diff of one changed line pair, so a UI
  can highlight only the differing span instead of the whole line. Same `CollectionDifference`
  approach, applied to tokens instead of lines.

### `SyntaxMap` — a structured map of a Markdown document's syntax ranges

`syntaxMap(of: String) -> [SyntaxElement]` parses with
[swift-markdown](https://github.com/apple/swift-markdown) and returns every heading, emphasis,
strong, inline code, code block, link, list item, block quote, thematic break, table, and math/
diagram element it finds, each tagged by `SyntaxKind` and — the point of this module — with its
**marker range(s) reported separately from its content range**. A live-preview layer hides exactly
the marker ranges when the cursor isn't on that line; a styled-source renderer can dim markers and
style content differently. Neither is possible from swift-markdown's own `Markup.range` alone,
which covers markers and content together (`**bold**`'s range is all nine characters, not just
`bold`).

All ranges are `TextRange`, UTF-16-offset-based (with an `nsRange` computed property) rather than
`Character`-based or the UTF-8-byte offsets swift-markdown's own `SourceLocation.column` uses —
because `NSTextStorage` addresses text in UTF-16 code units, and mixing up UTF-8 bytes,
`Character`/grapheme-cluster counts, and UTF-16 code units is exactly what causes off-by-one cursor
bugs around emoji, CJK text, and combining characters. See `LineOffsetTable`'s documentation for
the conversion this relies on.

Math (`$inline$`, `$$display$$`) and Mermaid diagram fences aren't part of CommonMark/GFM, so they
don't appear in swift-markdown's parse tree. Mermaid is detected as a fenced code block whose
info-string language is `mermaid`. Math is found by a separate raw-text scan (see
`SyntaxMapper.swift` for the delimiter heuristic and its known tradeoffs — distinguishing math
from currency punctuation like "$5" is inherently a convention, not a certainty).

**Deliberately lighter-weight treatment, flagged rather than silently glossed over:**
- **Tables**: reported as one `SyntaxKind.table` element with no marker/content split — the pipe
  grid isn't decomposed further.
- **Indented code blocks** (4-space indentation, no fence): reported as `.codeBlock` with the
  whole range as content and *no* marker ranges — the indentation itself isn't treated as a
  hideable marker. Fenced blocks (the practical default in modern Markdown) are fully handled.
- **ATX closing sequences** (`## Heading ##`) aren't specially recognized; swift-markdown excludes
  them from every child's range, so they'd currently be silently absorbed into the leading marker
  gap rather than reported as a distinct trailing marker.

### `LivePreview` — the range mapper and reveal logic behind live-preview editing

The pure logic underneath the app target's live-preview editor (Markdown markers hidden except on
the cursor's line; tables/math/Mermaid rendered inline except where the cursor is). Kept in this
package rather than the app target specifically so the coordinate math — the part where an
off-by-one silently drifts the cursor — is exhaustively, headlessly testable; see
`DisplayMapperTests.swift`'s brute-force cross-check against a naive `O(n²)` reference for the kind
of test this is meant to make possible.

- `DisplayMapper` — a bidirectional UTF-16 offset mapper between a document's *source* text (what's
  on disk) and its *display* text (what live-preview editing shows, with some ranges elided to zero
  width). `displayOffset(forSource:)`/`sourceOffset(forDisplay:)` and their `TextRange` counterparts
  are the only place this translation happens; every app-target call site that needs to reconcile
  "where the user clicked/typed" with "where that is in the saved file" goes through this rather
  than reimplementing the arithmetic. Built once per recompute from a flat list of hidden ranges —
  overlapping/adjacent ranges are merged automatically.
- `livePreviewSpans(source:elements:cursorSourceOffset:) -> [LivePreviewSpan]` — given a
  `syntaxMap(of:)` result and the cursor's current offset (or `nil` if hiding is off), decides what
  to hide (`.hiddenMarker`) and what to replace with a rendered image (`.renderedInline` for a
  single-line construct, `.renderedBlock` for a multi-line one — a table, a Mermaid diagram, or a
  multi-line `$$...$$`). Line-scoped, matching Obsidian's Live Preview: a marker or a
  single-line-replaceable construct is hidden/rendered unless the cursor is somewhere on its own
  source line; a multi-line block swaps back to raw source if the cursor is on *any* line it
  occupies, not just its first.
- `MarkdownTableHTML.render(_:) -> String?` — turns a GFM pipe table's raw source into minimal HTML
  for the app target's offscreen renderer to turn into an image. A small, GFM-shaped parser (not a
  second Markdown engine) with a light inline pass for `**bold**`/`*italic*`/`` `code` `` inside
  cells; anything fancier in a cell is left as literal text.

The app target bundles [KaTeX](https://katex.org) and [Mermaid](https://mermaid.js.org) (both
MIT-licensed — see `App/Resources/LivePreviewRender/KATEX_LICENSE` and `MERMAID_LICENSE`) to render
math and diagrams offscreen; neither is a dependency of this package, which stays swift-markdown-only.

### `WordCount` — word counting and reading-time estimation

A Swift port of `backend/word_count.py` from the `markdown-reader` project (MIT-licensed,
Copyright petertzy — see `LICENSE`). `WordCount.stripMarkdown`, `.countWords`, `.readingTime`, and
the combined `.analyze(_:) -> WordCountResult` mirror the original's Markdown-stripping regex
pipeline and CJK-aware counting (each CJK character counts as its own word, since those scripts
don't use spaces between words), including its reading-time rounding behavior — Python's `round()`
is banker's rounding (ties round to even), which is *not* the default for `Double.rounded()` in
Swift, so `WordCount.readingTime` explicitly uses `.rounded(.toNearestOrEven)` to match.

## Requirements

- Swift 6.2+ toolchain, macOS 26 SDK
- Depends on [swift-markdown](https://github.com/apple/swift-markdown) (pulls in `swift-cmark`
  transitively); no other third-party dependencies

## Building and testing

```sh
swift build
swift test
```

Tests use [Swift Testing](https://developer.apple.com/documentation/testing) (`@Test`/`#expect`),
not XCTest. 261+ tests as of Stage 5; `Core/Tests/MDEdCoreTests/` is organized one file per module
above.
