# MDEd

MDEd is a personal macOS Markdown editor, built from scratch in AppKit and TextKit 2 for the
macOS 26 SDK. It's a text editor first — every document is a plain `.md`/`.markdown`/`.txt` file on
disk, no proprietary format, no account, no sync service.

<!-- screenshot: docs/screenshot.png — a document open in live-preview mode, gutter visible -->

## What makes it different

- **Two-file comparison with both panes editable.** File ▸ Compare Two Files… opens a side-by-side
  diff view with hunk navigation and take-left/take-right — but unlike most diff tools, neither
  side is read-only. Edit either document directly in the comparison window; the diff recomputes
  live as you type.
- **Live-preview editing.** Markdown markers (`##`, `**`, `` ` ``, `>`, list bullets) hide
  themselves except on the line you're actively editing; tables, math (`$inline$`/`$$display$$`),
  and Mermaid diagrams render inline in place of their raw source. Toggle it off (View ▸ Hide
  Markdown Syntax, ⌘/) and it's a plain styled-source editor instead — markers dimmed, not hidden.
- **On-device AI, nothing leaving the machine.** Summarize, tighten a selection, translate, or
  summarize a two-file diff, all through Apple's on-device Foundation Models — no API key, no
  network request, no cloud provider. See [On-device AI](#on-device-ai) below for exactly what that
  means and where it currently struggles.

Also included: a source-line-number gutter (in both the editor and comparison panes), live
Settings (⌘,) that apply to every open window immediately, and a small set of deterministic
Markdown commands (Insert Table of Contents, Normalize Formatting) that don't touch the model at
all.

## Building and running

```sh
xcodegen generate
xcodebuild -scheme MDEd -derivedDataPath /tmp/mded-dd build
open /tmp/mded-dd/Build/Products/Debug/MDEd.app
```

Requires Xcode with the macOS 26 SDK. [XcodeGen](https://github.com/yonaskolb/XcodeGen) generates
`MDEd.xcodeproj` from `project.yml` — the `.xcodeproj` itself isn't committed, so `xcodegen
generate` is the first step after every clone and after any `project.yml` change.

`./Scripts/smoke-launch.sh` launches a built app against each file in `Samples/` and confirms it
survives opening the document without crashing — see the script's own header comment for why this
exists as a check independent of the test suite below.

### The core logic package

The pure Markdown/diff/live-preview logic underneath the app — no AppKit, no file I/O, fully
headless-testable — lives in `Core/` as its own Swift package, `MDEdCore`. See
**[`Core/README.md`](Core/README.md)** for its module-by-module documentation and its own build/test
instructions (`cd Core && swift build && swift test`; 261+ tests, all headless, no app build
required to run them).

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N | New document |
| ⌘O | Open… |
| ⌘W | Close |
| ⌘S | Save |
| ⇧⌘S | Save As… |
| ⇧⌘C | Compare Two Files… |
| ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌘X / ⌘C / ⌘V | Cut / Copy / Paste |
| ⌘A | Select All |
| ⌘F | Find… |
| ⌘G / ⇧⌘G | Find Next / Find Previous |
| ⌘E | Use Selection for Find |
| ⌘/ | Toggle live preview (View ▸ Hide Markdown Syntax) |
| ⌘, | Settings |
| ⌘M | Minimize |
| ⌘H / ⌥⌘H | Hide MDEd / Hide Others |
| ⌘Q | Quit |

A handful of commands are reachable only from the menu bar or toolbar, with no key equivalent
assigned: Revert to Saved, Compare Frontmost With…, everything in the Format and AI menus (Insert
Table of Contents, Normalize Formatting, Summarize/Tighten/Translate), and the toolbar's
Bold/Italic/Code/Link formatting buttons. All four toolbar formatting buttons and every menu item
are still reachable with Full Keyboard Access on (System Settings ▸ Keyboard ▸ Keyboard
navigation) — Tab cycles through the toolbar and every other control, and every control shows a
visible focus ring; nothing in this app suppresses either.

Checked for conflicts across the whole menu bar while building this: none found. A few items
(Revert to Saved, Zoom, Bring All to Front, everything under Format and AI) simply have no
shortcut at all, matching how Apple's own apps typically leave infrequent commands unbound rather
than assigning one for its own sake.

## On-device AI

Every AI command (Summarize Document, Tighten Selection, Translate Selection/Document, and the
comparison window's Summarize Changes) runs through Apple's on-device Foundation Models —
`SystemLanguageModel`, available once Apple Intelligence is turned on for a supported Mac. There is
no API key to configure and no other backend to switch to; see `AIService`'s doc comment in the
source for why the app is still built against a protocol despite having exactly one implementation.

What that means concretely:
- **Nothing leaves the machine.** No network request, ever — confirmed at the framework level, not
  just by omission of networking code.
- **4,096-token context window**, measured directly against the real model (not a published spec —
  see `TokenEstimator`'s doc comment for the calibration data point). `DocumentChunker` splits
  anything larger at heading/paragraph/sentence boundaries, never mid-sentence, so each piece fits.
- **23 languages** are supported by the underlying model; the Translate submenus offer a curated
  shortlist of eight for one-click access (English, Spanish, French, German, Portuguese, Japanese,
  Simplified Chinese, Korean) rather than the full list, since a giant menu or a free-text prompt
  both lose to "pick from a short list" for the common case.

**Known, measured weaknesses — fixes under consideration, not yet decided:**
- **Summarizing summaries degrades on very large documents.** A document that chunks into more
  than a handful of pieces gets summarized in a map-reduce pass (chunk summaries, then a summary
  of the summaries, recursively if even that combined list is still over budget). Past a shallow
  recursion depth, the command gives up compressing further and returns the numbered list of
  section summaries as-is rather than looping — readable, never an error, but visibly less
  polished than a document that fits in fewer passes.
- **A chunk that straddles two languages can fail.** `DocumentChunker` splits at heading,
  paragraph, and sentence boundaries — never at a language boundary — so a paragraph that itself
  mixes two languages can produce a chunk FoundationModels rejects with
  `GenerationError.unsupportedLanguageOrLocale`. Language-aware chunk boundaries would fix this;
  not yet implemented.
- **Tighten Selection sometimes adds Markdown emphasis that wasn't in the source**, despite being
  explicitly instructed to preserve exact Markdown syntax. This is a real, observed model behavior,
  not a bug in the instruction text. It's the reason every AI command in this app works the same
  way: the result always opens in a review sheet with Copy/Discard/Apply, and nothing is ever
  written into a document without that explicit click — see `AIReview`'s doc comment for why that
  guarantee is structural (one shared review surface, one place `onApply` can be reached from)
  rather than a convention each command has to remember to follow.

## Live preview: caret behavior through hidden markers

The one risk in live-preview editing flagged repeatedly but never verified before this stage: with
markers hidden, does the layout manager's "next caret position" (computed against the *shortened
display* text) remap back to the right *source* offset, or drift by a character around a hidden
run? **Tested directly against the running app** — caret movement (arrow keys in both directions)
and shift-arrow selection across hidden `**bold**`/`` `code` ``/`[link](url)`/heading marker runs
both land correctly, with no drift observed. This risk is closed.

## Known limitations

- **A brand-new, never-saved document's window isn't restored at relaunch.** Per-document window
  frame and Resume-style reopening (see below) both key off the document's file URL; a document
  that was never saved to disk has none, so quitting with an unsaved "Untitled" window open loses
  that window (not its unsaved text — `NSDocument`'s own autosave-in-place still protects that the
  same way it always has, just not as a window that reopens itself).
- **The three AI weaknesses above** are documented, not yet fixed or formally accepted — see that
  section.
- No notarization, sandboxing, App Store assets, update mechanism, cloud AI fallback, or
  import/export beyond plain `.md`/`.markdown`/`.txt` files. This is a personal tool, not a
  distributed product, and those are deliberately out of scope for now.

## Credit

This is a from-scratch rewrite, not a fork — but `Core/Sources/MDEdCore/WordCount/WordCount.swift`
is a Swift port of `backend/word_count.py` from the
[`markdown-reader`](https://github.com/petertzy/markdown-reader) project (MIT-licensed, Copyright
petertzy), including its CJK-aware word counting and its banker's-rounding reading-time estimate.
See [`LICENSE`](LICENSE) and that file's own doc comment.

## License

MIT — see [`LICENSE`](LICENSE).
