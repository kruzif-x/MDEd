# Acknowledgements

MDEd is a from-scratch editor, but it stands on a few shoulders:

- **[revdown](https://github.com/Roenbaeck/revdown)** (MIT) — the design of MDEd's review
  notes is indebted to it: comments in a sidecar file so the document stays byte-for-byte
  unchanged, and honestly-escalating anchor states (exact / relocated / ambiguous / unmatched)
  instead of silently re-attaching a note wherever it roughly fits.
- **[swift-markdown](https://github.com/apple/swift-markdown)** (MIT) — the Markdown parser
  underneath everything: syntax highlighting, the outline, word counting, the comparison
  engine, and the AI chunking all build on its block structure.
- **[markdown-reader](https://github.com/petertzy/markdown-reader)** (MIT, Copyright
  petertzy) — `WordCount` in MDEd's core is a Swift port of its `backend/word_count.py`,
  including CJK-aware word counting and its banker's-rounding reading-time estimate.
- **[KaTeX](https://github.com/KaTeX/KaTeX)** (MIT) — math typesetting for `$inline$` and
  `$$display$$` expressions in live preview.
- **[Mermaid](https://github.com/mermaid-js/mermaid)** (MIT) — diagram rendering for fenced
  ```mermaid blocks in live preview.

Full license texts for KaTeX and Mermaid ship inside the app
(`Contents/Resources/LivePreviewRender/`). Everything else in MDEd is original code,
open source under the MIT license, Copyright © 2026 Roland Chia — see the project's
`LICENSE` file.
