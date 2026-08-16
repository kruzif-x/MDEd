import Foundation

/// One heading entry in a generated table of contents.
public struct TOCEntry: Sendable, Equatable {
    /// The heading's level, 1–6 (an ATX `#` through `######`).
    public let level: Int
    /// The heading's text, Markdown emphasis/code/link syntax stripped (via `WordCount.stripMarkdown`)
    /// so a bolded or linked heading still reads as plain text in the list.
    public let title: String
    /// A GitHub-flavored-Markdown-style anchor slug derived from `title`, for a renderer that
    /// resolves `#slug` links (GitHub, and most static site generators, do).
    public let slug: String
    /// The heading element's full range in the source document (markers and content together).
    public let range: TextRange

    public init(level: Int, title: String, slug: String, range: TextRange) {
        self.level = level
        self.title = title
        self.slug = slug
        self.range = range
    }
}

/// Generates a table of contents from a document's headings — a pure function over
/// `syntaxMap(of:)`'s output, deliberately **not** model-generated: it's faster, exact, and
/// reproducible, none of which an on-device model would add anything to for a task this
/// mechanical. See `MarkdownFormatting` for the other deterministic command in this pairing.
public enum TableOfContents {

    /// Extracts every heading from `text`, in document order.
    public static func entries(from text: String) -> [TOCEntry] {
        syntaxMap(of: text).compactMap { element -> TOCEntry? in
            guard case .heading(let level) = element.kind else { return nil }
            let rawTitle = element.contentRange.map { utf16Substring(of: text, range: $0) } ?? ""
            let title = WordCount.stripMarkdown(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            return TOCEntry(level: level, title: title, slug: slug(for: title), range: element.range)
        }
    }

    /// Renders `entries` as a nested Markdown bullet list, each linking to its GFM-style anchor
    /// (`[Title](#slug)`), indented two spaces per level below the shallowest heading present —
    /// so a document that starts at `##` isn't given a redundant extra level of indentation.
    public static func renderMarkdown(_ entries: [TOCEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        let baseLevel = entries.map(\.level).min() ?? 1
        return entries
            .map { entry -> String in
                let indent = String(repeating: "  ", count: max(0, entry.level - baseLevel))
                let title = entry.title.isEmpty ? "Untitled" : entry.title
                return "\(indent)- [\(title)](#\(entry.slug))"
            }
            .joined(separator: "\n")
    }

    // MARK: - Slugs

    /// A GitHub-Flavored-Markdown-style anchor slug: lowercased, whitespace runs collapsed to a
    /// single hyphen, everything but letters/digits/hyphens/underscores dropped. Duplicate slugs
    /// within one document (two same-named headings) are **not** disambiguated with a trailing
    /// `-1`/`-2` the way GitHub's own renderer does — a known, deliberate simplification: nothing
    /// in this editor resolves `#slug` links itself, so a duplicate only matters to an external
    /// renderer, and disambiguating would require this function to see every heading in the
    /// document at once rather than staying a pure per-title mapping.
    private static func slug(for title: String) -> String {
        var result = ""
        var lastWasHyphen = false
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if scalar == "-" || scalar == "_" {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = scalar == "-"
            } else if scalar.properties.isWhitespace, !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Extracts the substring of `text` covered by `range`, a UTF-16 `TextRange` — the currency
    /// type `SyntaxElement` reports ranges in (see `TextRange`'s own documentation for why).
    private static func utf16Substring(of text: String, range: TextRange) -> String {
        let ns = text as NSString
        guard range.nsRange.location != NSNotFound, range.nsRange.location + range.nsRange.length <= ns.length else { return "" }
        return ns.substring(with: range.nsRange)
    }
}
