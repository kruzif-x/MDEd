# Edge cases

Deliberately awkward Markdown. `kitchen-sink.md` is the *representative* fixture — the one
to open when judging whether styling looks right. This file is the opposite: constructs that
are legal but pathological, kept separate so they can be opened by the smoke check without
degrading the visual reference.

Nothing here should crash the app, hang layout, or produce ranges that fall outside the
document. Several of these come from fuzzing that found real problems.

## Emphasis run lengths

Long delimiter runs make the parser's marker-versus-content split ambiguous, and the styler
resolves markers by subtracting children from their parent's range — so a run that produces
unexpected nesting is exactly where that logic breaks down.

- Four: ****four asterisks****
- Six: ******six asterisks******
- Eight: ********eight asterisks********
- Mismatched open and close: ***three open, two close**
- Underscores at eight: ________eight underscores________
- In a heading: see below
- Inside a list item: - [ ] a task with ********deep emphasis********

## ********A heading that is entirely emphasis********

## Partly ******emphasised****** heading

## Nesting and interleaving

Emphasis that **overlaps *its* neighbours** rather than nesting cleanly. Intraword
under_scores_should_not_emphasise. A literal \*escaped asterisk\* pair. Emphasis containing
`code with **asterisks** inside` it, which must not re-enter the emphasis parser.

Strong wrapping a link: **[a link inside strong](https://example.com)**. A link whose text
is itself emphasised: [***triple emphasis link***](https://example.com).

## Unterminated constructs

An opening fence with no closing fence, which makes the code block run to end of document if
the parser is naive:

```swift
struct Unterminated {
    let value: Int

## Degenerate blocks

An empty fenced block:

```
```

A block quote with nothing in it:

>

A table with a ragged row count:

| One | Two | Three |
| --- | --- | --- |
| only one cell |
| a | b | c | d |

## Whitespace and width

A line with trailing whitespace that matters for hard breaks:  
this line follows a two-space hard break.

A very long unbroken token that cannot wrap at any measure:
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

Deeply nested list, past the point of usefulness:

- one
  - two
    - three
      - four
        - five
          - six
            - seven

## Non-ASCII adjacent to markers

Emphasis hugging CJK: **中文加粗** and 日本語の**強調**、한국어 **강조**.

Emphasis hugging emoji: **🚀 launch** and *🍜 noodles*.

Combining characters next to a marker: **é** versus **é** — the first is precomposed, the
second is `e` plus a combining acute. Both must yield marker ranges that land on character
boundaries, since UTF-16 offsets into `NSTextStorage` are what the styler applies.
