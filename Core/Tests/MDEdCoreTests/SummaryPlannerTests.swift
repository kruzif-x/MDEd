import Foundation
import Testing
@testable import MDEdCore

@Suite("SummaryPlanner")
struct SummaryPlannerTests {

    @Test func headinglessDocumentReturnsNil() {
        let text = "Just a paragraph of prose with no headings at all in it whatsoever."
        #expect(SummaryPlanner.sectionPlan(for: text) == nil)
    }

    @Test func emptyDocumentReturnsNil() {
        #expect(SummaryPlanner.sectionPlan(for: "") == nil)
    }

    @Test func oneSectionPerTopLevelHeadingInOrder() {
        let text = """
        # Title

        Intro text.

        ## Installation

        Install steps here.

        ## Usage

        Usage steps here.
        """
        let sections = SummaryPlanner.sectionPlan(for: text)
        #expect(sections != nil)
        #expect(sections?.map(\.title) == ["Title", "Installation", "Usage"])
        #expect(sections?.map(\.level) == [1, 1, 1])
    }

    @Test func onlyTopLevelHeadingsStartNewSections() {
        // A document that starts at `##` — the shallowest level present (2) is "top-level"; a `###`
        // subsection stays folded into its parent's section text rather than becoming its own.
        let text = """
        ## Section One

        Some text.

        ### Nested Subsection

        Nested text.

        ## Section Two

        More text.
        """
        let sections = SummaryPlanner.sectionPlan(for: text)
        #expect(sections?.map(\.title) == ["Section One", "Section Two"])
        #expect(sections?[0].chunks.first?.text.contains("Nested Subsection") == true)
    }

    @Test func preambleBeforeFirstHeadingBecomesAnUntitledSection() {
        let text = """
        This is text before any heading.

        # First Heading

        Body.
        """
        let sections = SummaryPlanner.sectionPlan(for: text)
        #expect(sections?.count == 2)
        #expect(sections?[0].title == nil)
        #expect(sections?[0].level == 0)
        #expect(sections?[0].chunks.first?.text.contains("before any heading") == true)
        #expect(sections?[1].title == "First Heading")
    }

    @Test func noPreambleSectionWhenDocumentStartsAtAHeading() {
        let text = "# Title\n\nBody text right away."
        let sections = SummaryPlanner.sectionPlan(for: text)
        #expect(sections?.count == 1)
        #expect(sections?[0].title == "Title")
    }

    @Test func wholeDocumentPartitionsWithNoGapsOrOverlaps() {
        let text = """
        # Title

        Alpha.

        ## Beta

        Bravo.

        ## Gamma

        Delta.
        """
        let sections = SummaryPlanner.sectionPlan(for: text)!
        // Each section fits in one chunk here (well under budget), so concatenating every section's
        // chunk text in order reconstructs the original document exactly — no gap, no overlap, no
        // dropped or duplicated character at a section boundary.
        let joined = sections.flatMap(\.chunks).map(\.text).joined()
        #expect(joined == text)
    }

    @Test func oversizedSectionIsSplitIntoMultipleChunksByDocumentChunker() {
        let bigBody = Array(0..<400).map { "word\($0)" }.joined(separator: " ")
        let text = "# Title\n\n\(bigBody)"
        let sections = SummaryPlanner.sectionPlan(for: text, budgetTokens: 50, estimator: { $0.split(separator: " ").count })!
        #expect(sections.count == 1)
        #expect(sections[0].chunks.count > 1)
    }

    @Test func documentWithSeveralHashHeadingsAndNoDoubleHashSplitsAtLevelOne() {
        // No `##` anywhere, but three `#` headings — the split level has to fall back to the one
        // level that's actually present and repeats, same as it always did before the "solitary
        // title" special case existed.
        let text = """
        # Alpha

        Alpha body.

        # Beta

        Beta body.

        # Gamma

        Gamma body.
        """
        let sections = SummaryPlanner.sectionPlan(for: text)
        #expect(sections?.map(\.title) == ["Alpha", "Beta", "Gamma"])
        #expect(sections?.map(\.level) == [1, 1, 1])
    }

    @Test func customChunkerIsUsedInPlaceOfDocumentChunker() {
        // `AICommandRunner` passes `LanguageAwareChunker.chunk` here in the real app; pinned with a
        // trivial spy instead so this test doesn't depend on that type's own behavior.
        var sectionsSeenByChunker: [String] = []
        let text = "# Title\n\nBody text.\n\n## Section\n\nMore body text."
        let sections = SummaryPlanner.sectionPlan(for: text, chunker: { sectionText, budget, estimator in
            sectionsSeenByChunker.append(sectionText)
            return DocumentChunker.chunk(sectionText, budgetTokens: budget, estimator: estimator)
        })
        #expect(sections != nil)
        #expect(sectionsSeenByChunker.count == sections?.count)
    }

    @Test func duplicateHeadingTitlesEachGetTheirOwnSection() {
        let text = "# One\n\nBody one.\n\n# One\n\nBody two."
        let sections = SummaryPlanner.sectionPlan(for: text)
        #expect(sections?.count == 2)
        #expect(sections?[0].chunks.first?.text.contains("Body one") == true)
        #expect(sections?[1].chunks.first?.text.contains("Body two") == true)
    }
}
