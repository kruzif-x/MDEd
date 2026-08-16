import Foundation

/// Deterministic Markdown formatting cleanup — a pure function over `syntaxMap(of:)` and a couple
/// of line-oriented scans, deliberately **not** model-generated. A model is slower, non-reproducible
/// (the same document could normalize slightly differently between runs), and adds nothing here:
/// every rule below has one unambiguous correct answer, which is exactly the case a plain function
/// suits better than an LLM call. See `TableOfContents` for the other command in this pairing.
///
/// Four rules, each conservative by design — this cleans up accidental mess, it doesn't impose a
/// house style:
/// 1. **Heading marker spacing** — `#Title` / `#   Title` → `# Title`: exactly one space between
///    the `#` run and the heading text.
/// 2. **List marker spacing** — `-   item` → `- item` (also normalizes the gap around a task-list
///    checkbox, e.g. `-   [ ]   item` → `- [ ] item`): exactly one space after the marker.
/// 3. **Trailing whitespace** — trimmed from the end of every line, *except* a line ending in two
///    or more spaces is left untouched, since CommonMark treats that as a deliberate hard line
///    break (`<br>`); only a lone trailing space (never meaningful) or trailing tabs are trimmed.
/// 4. **Blank-line runs** — three or more consecutive blank lines collapse to exactly one.
///
/// All four skip the interior of fenced code blocks (see `FencedCodeTracker`), where whitespace —
/// including "excessive" blank lines — can be part of the code's own meaning, not accidental mess.
public enum MarkdownFormatting {

    public static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let documentLines = DocumentLines(text)
        let insideFence = FencedCodeTracker.linesInsideFence(documentLines.lines)

        var edits: [TextEdit] = []
        var consumedLineIndices = Set<Int>()

        edits.append(contentsOf: blankRunEdits(documentLines, insideFence: insideFence, consumed: &consumedLineIndices))
        edits.append(contentsOf: trailingWhitespaceEdits(documentLines, insideFence: insideFence, consumed: consumedLineIndices))
        edits.append(contentsOf: markerSpacingEdits(text))

        return apply(edits, to: text)
    }

    // MARK: - Rule 1 & 2: marker spacing (headings, list items)

    /// Collapses every run of two or more literal spaces inside a heading's or list item's leading
    /// marker gap (the `#`/bullet plus everything up to the content — which, for a task list item,
    /// includes the `[ ]`/`[x]` checkbox) down to a single space. Only the gap's *spacing* changes;
    /// the marker characters themselves (and the checkbox, if present) are left exactly as written.
    private static func markerSpacingEdits(_ text: String) -> [TextEdit] {
        let ns = text as NSString
        var edits: [TextEdit] = []
        for element in syntaxMap(of: text) {
            switch element.kind {
            case .heading, .listItem:
                break
            default:
                continue
            }
            guard let marker = element.markerRanges.first else { continue }
            let raw = ns.substring(with: marker.nsRange)
            let normalized = collapseSpaceRuns(raw)
            guard normalized != raw else { continue }
            edits.append(TextEdit(range: marker, replacementText: normalized))
        }
        return edits
    }

    /// Replaces every run of two or more `" "` characters in `text` with a single `" "`. Tabs and
    /// non-space whitespace are left alone (irrelevant here — marker gaps are space-delimited).
    private static func collapseSpaceRuns(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var run = 0
        for character in text {
            if character == " " {
                run += 1
                if run == 1 { result.append(character) }
            } else {
                run = 0
                result.append(character)
            }
        }
        return result
    }

    // MARK: - Rule 3: trailing whitespace

    private static func trailingWhitespaceEdits(_ documentLines: DocumentLines, insideFence: [Bool], consumed: Set<Int>) -> [TextEdit] {
        var edits: [TextEdit] = []
        for index in documentLines.lines.indices {
            guard !insideFence[index], !consumed.contains(index) else { continue }
            let line = documentLines.lines[index]
            guard let trimmed = trailingWhitespaceTrimmed(line) else { continue }
            edits.append(TextEdit(range: documentLines.lineRanges[index], replacementText: trimmed))
        }
        return edits
    }

    /// Returns `line` with its trailing whitespace removed, or `nil` if nothing should change —
    /// either because there's no trailing whitespace, or because it's two-or-more trailing spaces
    /// (a CommonMark hard line break; see this type's doc comment).
    private static func trailingWhitespaceTrimmed(_ line: String) -> String? {
        guard let lastContent = line.lastIndex(where: { $0 != " " && $0 != "\t" }) else {
            // The whole line is whitespace (or it's already empty).
            return line.isEmpty ? nil : ""
        }
        let trailing = line[line.index(after: lastContent)...]
        guard !trailing.isEmpty else { return nil }
        let trailingSpaceCount = trailing.count { $0 == " " }
        if trailing.contains("\t") || trailingSpaceCount < 2 {
            return String(line[...lastContent])
        }
        return nil
    }

    // MARK: - Rule 4: blank-line runs

    /// Finds every fence-external run of three or more consecutive blank lines and produces a
    /// deletion edit collapsing each down to one blank line, recording every line index the run
    /// touches in `consumed` so `trailingWhitespaceEdits` doesn't also try to edit (now-deleted)
    /// text inside the same span.
    private static func blankRunEdits(_ documentLines: DocumentLines, insideFence: [Bool], consumed: inout Set<Int>) -> [TextEdit] {
        func isBlank(_ index: Int) -> Bool {
            !insideFence[index] && documentLines.lines[index].trimmingCharacters(in: .whitespaces).isEmpty
        }

        var edits: [TextEdit] = []
        var index = 0
        let count = documentLines.lines.count
        while index < count {
            guard isBlank(index) else { index += 1; continue }
            var end = index
            while end < count, isBlank(end) { end += 1 }
            let runLength = end - index
            if runLength >= 3 {
                let start = documentLines.lineRanges[index].lowerBound
                let stop = documentLines.lineRanges[end - 1].upperBound
                edits.append(TextEdit(range: TextRange(lowerBound: start, upperBound: stop), replacementText: ""))
                for lineIndex in index..<end { consumed.insert(lineIndex) }
            }
            index = end
        }
        return edits
    }

    // MARK: - Applying edits

    /// Applies non-overlapping `edits` to `text`, in descending offset order so each edit's range
    /// stays valid regardless of how earlier (lower-offset) edits shift what follows them.
    private static func apply(_ edits: [TextEdit], to text: String) -> String {
        guard !edits.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            mutable.replaceCharacters(in: edit.range.nsRange, with: edit.replacementText)
        }
        return mutable as String
    }
}
