/// Renders the raw source text of one GFM pipe table (a `SyntaxElement` of kind `.table`, whole
/// range — see the package README for why `syntaxMap(of:)` doesn't decompose a table any further
/// than that) into a minimal, self-contained HTML `<table>` — the input the app target's offscreen
/// `WKWebView` renderer feeds to produce the table's live-preview image.
///
/// This is a deliberately small, GFM-shaped parser (header row, `---`/`:--`/`--:`/`:-:` alignment
/// row, body rows, `\|` as an escaped pipe) rather than a second Markdown engine — swift-markdown
/// itself has already validated that this text is a table by the time `.table` is reported, so the
/// job here is reformatting, not parsing from scratch. Cell text gets a minimal inline pass
/// (`**bold**`, `*italic*`, `` `code` ``) since table cells commonly carry that much emphasis and a
/// live-preview render that dropped it entirely would look conspicuously wrong; anything fancier
/// inside a cell (links, nested structures) is left as literal escaped text.
public enum MarkdownTableHTML {

    /// `nil` if `source` doesn't parse as at least a header row and its alignment row (e.g. the
    /// element's range was measured on stale/inconsistent text) — the caller should fall back to
    /// showing raw source rather than rendering a malformed table.
    public static func render(_ source: String) -> String? {
        let rawLines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lines = rawLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }

        let header = splitRow(lines[0])
        guard let alignments = parseAlignmentRow(lines[1]), !header.isEmpty else { return nil }
        let bodyRows = lines.dropFirst(2).map(splitRow)

        var html = "<table>\n<thead>\n<tr>"
        for (index, cell) in header.enumerated() {
            let align = index < alignments.count ? alignments[index] : .none
            html += "<th\(align.styleAttribute)>\(inlineHTML(cell))</th>"
        }
        html += "</tr>\n</thead>\n<tbody>\n"
        for row in bodyRows {
            html += "<tr>"
            for index in 0..<header.count {
                let cell = index < row.count ? row[index] : ""
                let align = index < alignments.count ? alignments[index] : .none
                html += "<td\(align.styleAttribute)>\(inlineHTML(cell))</td>"
            }
            html += "</tr>\n"
        }
        html += "</tbody>\n</table>"
        return html
    }

    private enum Alignment {
        case none, left, center, right
        var styleAttribute: String {
            switch self {
            case .none: return ""
            case .left: return " style=\"text-align:left\""
            case .center: return " style=\"text-align:center\""
            case .right: return " style=\"text-align:right\""
            }
        }
    }

    /// Splits one `| a | b |` source line into its cell texts, honoring `\|` as a literal pipe
    /// rather than a cell separator and tolerating missing leading/trailing pipes (both are legal
    /// GFM table syntax).
    private static func splitRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }

        var cells: [String] = []
        var current = ""
        var previousWasBackslash = false
        for char in trimmed {
            if char == "|" && !previousWasBackslash {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
            previousWasBackslash = (char == "\\") && !previousWasBackslash
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    /// `nil` if `line` isn't a valid GFM alignment row (every cell must be made of only `-`/`:`,
    /// with at least one `-`).
    private static func parseAlignmentRow(_ line: String) -> [Alignment]? {
        let cells = splitRow(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [Alignment] = []
        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "-" || $0 == ":" }), trimmed.contains("-") else {
                return nil
            }
            let left = trimmed.hasPrefix(":")
            let right = trimmed.hasSuffix(":")
            switch (left, right) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.left)
            case (false, true): alignments.append(.right)
            case (false, false): alignments.append(.none)
            }
        }
        return alignments
    }

    /// A minimal inline pass: HTML-escapes the cell text, then re-introduces `<strong>`/`<em>`/
    /// `<code>` for the common, unambiguous, non-nested cases. Deliberately not a full inline
    /// Markdown parser — see this type's documentation.
    private static func inlineHTML(_ text: String) -> String {
        var escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        escaped = replacing(escaped, pattern: "\\*\\*(.+?)\\*\\*", template: "<strong>$1</strong>")
        escaped = replacing(escaped, pattern: "__(.+?)__", template: "<strong>$1</strong>")
        escaped = replacing(escaped, pattern: "(?<!\\*)\\*([^*]+?)\\*(?!\\*)", template: "<em>$1</em>")
        escaped = replacing(escaped, pattern: "`(.+?)`", template: "<code>$1</code>")
        return escaped
    }

    private static func replacing(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

import Foundation
