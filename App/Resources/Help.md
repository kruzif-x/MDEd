# MDEd Help

MDEd is a plain-text Markdown editor. Every document is an ordinary `.md`, `.markdown`, or
`.txt` file on disk — nothing is locked into a proprietary format, and nothing leaves your
machine.

## Editing

You are always editing the Markdown *source*, styled as you type: headings, emphasis, code
blocks, tables, and quotes are colored and sized so the structure reads at a glance, while the
markers themselves (`##`, `**`, `` ` ``, `>`) stay visible and typable. The toolbar and the
Format menu wrap the selection in markers for you; Format ▸ Normalize Formatting tidies marker
spacing, trailing whitespace, and blank-line runs in one undoable step.

The text column is centered at a fixed measure chosen in Settings, so lines stay a comfortable
length no matter how wide the window is. The status bar shows word count, reading time, and
your line/column position; line numbers live in the gutter on the left (toggle them in
Settings ▸ Show line numbers).

## Live preview

With live preview on (View ▸ Hide Markdown Syntax, ⌘/), Markdown markers hide themselves
everywhere except the line you're actively editing — write `**bold**` and it reads as bold the
moment the caret leaves the line. Tables, math (`$inline$` and `$$display$$`), and Mermaid
diagrams render in place as images. With it off, you get the plain styled-source view. The
same toggle lives in Settings if you prefer it sticky.

## Document outline

The outline sidebar (View ▸ Show Outline, ⌥⌘S, or the toolbar's sidebar button) lists every
heading, nested by level. Click an entry to jump to it; the entry containing your caret
highlights itself as you move through the document.

## Review notes

Notes are annotations pinned to a passage of text — the document itself is never touched.

1. Select some text and choose Notes ▸ Add Note to Selection (⌥⌘N, or the toolbar button).
2. Write the note. It appears as a colored bar beside the passage and a dot in the gutter.
3. Click the gutter dot to read, edit, reveal, or delete the note. Notes ▸ Show All Notes
   lists every note, including ones whose text no longer exists.

Notes keep track of their passage as you edit. Each note's status says how confident it is:

| Status | Meaning |
| --- | --- |
| Anchored | The passage and its surroundings still match — even if everything shifted. |
| Moved | The passage survives, but the text around it changed. |
| Ambiguous | The passage now occurs more than once; MDEd won't guess which one. |
| Unmatched | The passage is gone. Delete the note, or let it sit as a to-do. |

Notes are stored in a sidecar file next to the document (for `notes.md`, that's
`notes.md.mded-notes.json`), so plain files stay plain and the notes travel with the document
in version control. On a never-saved document, notes live in memory until the first save.

## Comparing two files

File ▸ Compare Two Files… (⇧⌘C) opens a side-by-side diff of any two text files, and File ▸
Compare Frontmost With… compares the document you're editing against a chosen file. Neither
side is read-only: type in either pane and the diff recomputes live. Use the control bar to
step through differences, take one side's version of the current hunk, switch to parallel
reading (both files shown whole, changes tinted), or toggle synchronized scrolling.

## On-device AI

The AI menu summarizes, tightens a selection, or translates — entirely on this Mac through
Apple's on-device foundation models. No API key, no account, no network request. Results are
never applied automatically: each one opens in a review sheet where you read it, copy it, or
explicitly apply it. When a result would introduce Markdown formatting that wasn't in the
original, a warning says exactly what, so structure changes never slip by unnoticed.

On-device AI requires macOS with Apple Intelligence available. If it isn't, the AI menu
explains what's missing.

## Settings

Settings (⌘,) applies to every open window immediately: font family and size, the monospaced
typeface used for code, measure width, line and paragraph spacing, line numbers, live
preview, and light/dark theme.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N / ⌘O / ⌘W | New / Open… / Close |
| ⌘S / ⇧⌘S | Save / Save As… |
| ⇧⌘C | Compare Two Files… |
| ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌘X / ⌘C / ⌘V | Cut / Copy / Paste |
| ⌘A | Select All |
| ⌘F | Find… |
| ⌘G / ⇧⌘G | Find Next / Find Previous |
| ⌘E | Use Selection for Find |
| ⌘/ | Toggle live preview |
| ⌥⌘S | Toggle the outline sidebar |
| ⌥⌘N | Add a review note to the selection |
| ⌘, | Settings |
| ⌘? | Open this window |

Menu-bar and toolbar commands without shortcuts — Revert to Saved, Compare Frontmost With…,
Show All Notes, Insert Table of Contents, Normalize Formatting, and the AI commands — are all
reachable with Full Keyboard Access on.
