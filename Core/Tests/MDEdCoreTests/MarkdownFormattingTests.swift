import Testing
@testable import MDEdCore

@Suite("MarkdownFormatting")
struct MarkdownFormattingTests {

    // MARK: - Heading spacing

    @Test func collapsesExcessSpaceAfterHeadingMarker() {
        #expect(MarkdownFormatting.normalize("#    Title") == "# Title")
    }

    @Test func leavesCorrectlySpacedHeadingUnchanged() {
        #expect(MarkdownFormatting.normalize("## Title") == "## Title")
    }

    @Test func normalizesHeadingSpacingAtEveryLevel() {
        #expect(MarkdownFormatting.normalize("###      Deep") == "### Deep")
    }

    // MARK: - List marker spacing

    @Test func collapsesExcessSpaceAfterListMarker() {
        #expect(MarkdownFormatting.normalize("-    item") == "- item")
    }

    @Test func collapsesExcessSpaceAroundTaskListCheckbox() {
        #expect(MarkdownFormatting.normalize("-    [ ]    item") == "- [ ] item")
    }

    @Test func collapsesExcessSpaceAfterOrderedListMarker() {
        #expect(MarkdownFormatting.normalize("1.     item") == "1. item")
    }

    // MARK: - Trailing whitespace

    @Test func trimsSingleTrailingSpace() {
        #expect(MarkdownFormatting.normalize("Hello world \nNext line") == "Hello world\nNext line")
    }

    @Test func trimsTrailingTabs() {
        #expect(MarkdownFormatting.normalize("Hello\t\t\nWorld") == "Hello\nWorld")
    }

    @Test func preservesTwoTrailingSpacesAsAHardLineBreak() {
        let text = "Hello world  \nNext line"
        #expect(MarkdownFormatting.normalize(text) == text)
    }

    @Test func preservesThreeOrMoreTrailingSpacesTooRatherThanRiskingAHardBreak() {
        let text = "Hello world   \nNext line"
        #expect(MarkdownFormatting.normalize(text) == text)
    }

    @Test func blankLineWithStraySpacesBecomesFullyEmpty() {
        let text = "Paragraph one.\n   \nParagraph two."
        #expect(MarkdownFormatting.normalize(text) == "Paragraph one.\n\nParagraph two.")
    }

    // MARK: - Blank-line runs

    @Test func collapsesThreeOrMoreBlankLinesToOne() {
        let text = "Paragraph one.\n\n\n\nParagraph two."
        #expect(MarkdownFormatting.normalize(text) == "Paragraph one.\n\nParagraph two.")
    }

    @Test func leavesExactlyTwoBlankLinesAlone() {
        let text = "Paragraph one.\n\n\nParagraph two." // exactly one blank line between them
        #expect(MarkdownFormatting.normalize(text) == text)
    }

    @Test func collapsesManyBlankLinesToOne() {
        let text = "A.\n\n\n\n\n\n\n\nB."
        #expect(MarkdownFormatting.normalize(text) == "A.\n\nB.")
    }

    // MARK: - Fence awareness

    @Test func doesNotTouchTrailingWhitespaceInsideFencedCode() {
        let text = "```\ncode line   \n```"
        #expect(MarkdownFormatting.normalize(text) == text)
    }

    @Test func doesNotCollapseBlankLinesInsideFencedCode() {
        let text = "```\nline one\n\n\n\nline two\n```"
        #expect(MarkdownFormatting.normalize(text) == text)
    }

    @Test func doesNotTreatHashInFencedCodeAsAHeadingMarker() {
        let text = "```\n#    not a heading\n```"
        #expect(MarkdownFormatting.normalize(text) == text)
    }

    // MARK: - Idempotence & no-ops

    @Test func alreadyCleanDocumentIsUnchanged() {
        let text = "# Title\n\nA paragraph.\n\n## Section\n\n- item one\n- item two\n"
        #expect(MarkdownFormatting.normalize(text) == text)
    }

    @Test func isIdempotent() {
        let messy = "#   Title\n\n\n\n\nParagraph with trailing space \nand a tab\t\n\n-   item"
        let once = MarkdownFormatting.normalize(messy)
        let twice = MarkdownFormatting.normalize(once)
        #expect(once == twice)
    }

    @Test func emptyDocumentStaysEmpty() {
        #expect(MarkdownFormatting.normalize("") == "")
    }

    // MARK: - Combined pass

    @Test func normalizesMultipleIssuesInOneDocumentAtOnce() {
        let messy = "#    Title\n\n\n\n\nParagraph one.  \n\n-    item one\n-   item two   "
        // Heading spacing collapsed, the 3-blank-line run collapsed to one, list marker spacing
        // collapsed on both items — but "Paragraph one."'s 2 trailing spaces and "item two"'s 3
        // trailing spaces are both preserved (2+ trailing spaces, the hard-line-break rule, applies
        // per line regardless of what follows — see `preservesThreeOrMoreTrailingSpacesTooRatherThanRiskingAHardBreak`).
        let expected = "# Title\n\nParagraph one.  \n\n- item one\n- item two   "
        #expect(MarkdownFormatting.normalize(messy) == expected)
    }
}
