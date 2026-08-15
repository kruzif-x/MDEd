import Testing
@testable import MDEdCore

@Suite("MarkdownTableHTML")
struct MarkdownTableHTMLTests {

    @Test func basicTableRendersHeaderAndBodyRows() {
        let source = "| Name | Age |\n|------|-----|\n| Alice | 30 |\n| Bob | 25 |"
        let html = MarkdownTableHTML.render(source)
        #expect(html != nil)
        #expect(html!.contains("<th"))
        #expect(html!.contains("Name"))
        #expect(html!.contains("Alice"))
        #expect(html!.contains("Bob"))
        #expect(html!.contains("<tbody>"))
    }

    @Test func alignmentRowMapsToTextAlignStyles() {
        let source = "| L | C | R |\n|:--|:-:|--:|\n| a | b | c |"
        let html = MarkdownTableHTML.render(source)!
        #expect(html.contains("text-align:left"))
        #expect(html.contains("text-align:center"))
        #expect(html.contains("text-align:right"))
    }

    @Test func missingLeadingTrailingPipesStillParse() {
        let source = "a | b\n---|---\n1 | 2"
        let html = MarkdownTableHTML.render(source)
        #expect(html != nil)
        #expect(html!.contains(">a<") || html!.contains(">a</th>"))
    }

    @Test func escapedPipeInsideCellIsNotTreatedAsASeparator() {
        let source = "| a\\|b | c |\n|---|---|\n| 1 | 2 |"
        let html = MarkdownTableHTML.render(source)!
        #expect(html.contains("a|b"))
    }

    @Test func htmlSpecialCharactersAreEscaped() {
        let source = "| a | b |\n|---|---|\n| <script> | 1 & 2 |"
        let html = MarkdownTableHTML.render(source)!
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("&amp;"))
    }

    @Test func inlineEmphasisInCellsRenders() {
        let source = "| a |\n|---|\n| **bold** and *em* and `code` |"
        let html = MarkdownTableHTML.render(source)!
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>em</em>"))
        #expect(html.contains("<code>code</code>"))
    }

    @Test func malformedInputReturnsNil() {
        #expect(MarkdownTableHTML.render("just one line") == nil)
        #expect(MarkdownTableHTML.render("") == nil)
        #expect(MarkdownTableHTML.render("| a | b |\n| not an alignment row |") == nil)
    }

    @Test func rowsShorterThanHeaderPadWithEmptyCells() {
        let source = "| a | b | c |\n|---|---|---|\n| 1 |"
        let html = MarkdownTableHTML.render(source)
        #expect(html != nil)
        // Should not crash / should still emit 3 <td> for the short row.
        let tdCount = html!.components(separatedBy: "<td").count - 1
        #expect(tdCount == 3)
    }
}
