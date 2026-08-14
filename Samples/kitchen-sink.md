# MDEd Kitchen Sink

A working document meant to exercise every construct the styler currently handles — headings,
inline styles, code, links, lists, quotes, breaks, tables, and non-ASCII text.

## Headings, from here down to the smallest

### A third-level heading about nothing in particular

#### A fourth-level heading, still readable

##### Fifth level, getting small

###### Sixth level, the smallest ATX heading

## Inline emphasis

Plain prose sits here for contrast. This sentence has *emphasis with asterisks* and also
_emphasis with underscores_, plus **strong with asterisks** and __strong with underscores__. You
can of course combine them: **strong text with *nested emphasis* inside it**, and mark text as
~~no longer true~~ with strikethrough. Somewhere in the middle of a sentence there's `inline code`
that should pick up a subtle background without disturbing the surrounding monospaced flow.

## Code

A fenced block with a language tag, so a future increment could add real language-specific
highlighting on top of this:

```swift
struct Editor {
    let name: String

    func describe() -> String {
        "MDEd renders \(name) as styled source, not a live preview."
    }
}
```

And a fence with no info string at all:

```
$ mded Samples/kitchen-sink.md
Opened 1 document.
```

## Links

Two flavors: an [inline link with a title](https://example.com/mded "MDEd project page") and a
bare autolinked destination inside plain text like <https://example.com>. There's also a
[reference-style link][ref] to make sure that shape parses too.

[ref]: https://example.com/reference "A reference-style destination"

## Lists

Unordered, with nesting:

- First item, top level
- Second item, top level
  - Nested item, one level deep
  - Another nested item
    - Nested two levels deep
- Third item, back at the top, with **bold** and `code` mixed in

Ordered, with nesting:

1. Read the syntax map
2. Split markers from content
   1. Markers get dimmed
   2. Content gets styled
3. Reparse on a debounce, not on every keystroke

A task list, since it shares the list-item marker mechanism:

- [x] Parse Markdown into a syntax map
- [x] Style headings, emphasis, and code
- [ ] Live-preview marker hiding (a later increment)
- [ ] Two-pane diff view (a later increment)

## Blockquotes

> A single-line block quote, styled as a distinct, quieter voice than the surrounding prose.

> A multi-line block quote.
> Every line here repeats its own `>` marker,
> which is exactly why `SyntaxElement.markerRanges` reports one range per line for this kind
> rather than a single leading/trailing pair.

## A thematic break follows

---

Text resumes below the break above.

## A table

| Feature              | Status      | Notes                              |
| --------------------- | ----------- | ----------------------------------- |
| Styled source         | Done        | This document is the proof          |
| Live-preview hiding    | Not yet     | Markers stay visible on purpose     |
| Two-pane diff          | Not yet     | Diff engine exists in `MDEdCore`    |
| CJK-aware word count   | Done        | See the paragraph below             |

## Non-ASCII text

English, mixed with 中文（简体和繁體概念上都算）、日本語のひらがな・カタカナ、そして한국어 한글까지
— all of which count as individual "words" for reading-time purposes rather than being grouped
into space-delimited runs. And, for good measure, a few emoji: 📝 ✍️ 🎉 🚀 — plus an accented Latin
phrase: café, naïve, façade, Zürich.

That's the kitchen sink. If headings, emphasis, strong, strikethrough, inline code, a fenced code
block, links (inline, autolink, and reference), nested ordered/unordered/task lists, a block
quote, a thematic break, a table, and non-ASCII text all render with sensible styling and dimmed
(but visible) markers, this document has done its job.
