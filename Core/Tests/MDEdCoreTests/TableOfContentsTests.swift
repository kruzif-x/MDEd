import Foundation
import Testing
@testable import MDEdCore

@Suite("TableOfContents")
struct TableOfContentsTests {

    @Test func extractsHeadingsInOrderWithLevels() {
        let text = "# Title\n\nSome text.\n\n## Section One\n\nMore text.\n\n### Subsection\n\n## Section Two"
        let entries = TableOfContents.entries(from: text)
        #expect(entries.map(\.level) == [1, 2, 3, 2])
        #expect(entries.map(\.title) == ["Title", "Section One", "Subsection", "Section Two"])
    }

    @Test func noHeadingsProducesNoEntries() {
        #expect(TableOfContents.entries(from: "Just a paragraph, no headings here.").isEmpty)
    }

    @Test func stripsInlineMarkdownFromHeadingTitles() {
        // Reuses `WordCount.stripMarkdown`, which strips inline code *content* along with its
        // backticks (matching its own documented, already-tested behavior) — so this checks the
        // markers are gone rather than pinning stripMarkdown's exact spacing, which isn't this
        // type's concern to re-test.
        let entries = TableOfContents.entries(from: "# **Bold** and `code` and [a link](url)")
        #expect(entries.count == 1)
        let title = entries[0].title
        #expect(!title.contains("*"))
        #expect(!title.contains("`"))
        #expect(!title.contains("["))
        #expect(title.contains("Bold"))
        #expect(title.contains("a link"))
    }

    @Test func slugsAreLowercasedAndHyphenated() {
        let entries = TableOfContents.entries(from: "# Getting Started: A Guide!")
        #expect(entries[0].slug == "getting-started-a-guide")
    }

    @Test func slugsCollapseRepeatedWhitespaceToOneHyphen() {
        let entries = TableOfContents.entries(from: "#   Multiple   Spaces   Here")
        #expect(entries[0].slug == "multiple-spaces-here")
    }

    @Test func renderMarkdownProducesNestedBulletList() {
        let entries = [
            TOCEntry(level: 1, title: "Top", slug: "top", range: TextRange(lowerBound: 0, upperBound: 0)),
            TOCEntry(level: 2, title: "Child", slug: "child", range: TextRange(lowerBound: 0, upperBound: 0)),
        ]
        let markdown = TableOfContents.renderMarkdown(entries)
        #expect(markdown == "- [Top](#top)\n  - [Child](#child)")
    }

    @Test func renderMarkdownIndentsRelativeToShallowestHeadingPresent() {
        // Document starts at ## — should not get an extra, meaningless indent level.
        let entries = [
            TOCEntry(level: 2, title: "A", slug: "a", range: TextRange(lowerBound: 0, upperBound: 0)),
            TOCEntry(level: 3, title: "B", slug: "b", range: TextRange(lowerBound: 0, upperBound: 0)),
        ]
        let markdown = TableOfContents.renderMarkdown(entries)
        #expect(markdown == "- [A](#a)\n  - [B](#b)")
    }

    @Test func emptyEntriesRenderEmptyString() {
        #expect(TableOfContents.renderMarkdown([]).isEmpty)
    }

    @Test func headingRangesPointBackToTheSourceHeading() {
        let text = "Preamble.\n\n## Section Heading\n\nBody."
        let entries = TableOfContents.entries(from: text)
        #expect(entries.count == 1)
        let ns = text as NSString
        #expect(ns.substring(with: entries[0].range.nsRange) == "## Section Heading")
    }

    @Test func headingInsideFencedCodeBlockIsNotTreatedAsAHeading() {
        let text = "```\n# not a heading\n```\n\n# real heading"
        let entries = TableOfContents.entries(from: text)
        #expect(entries.map(\.title) == ["real heading"])
    }
}
