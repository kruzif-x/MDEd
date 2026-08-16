import Testing
@testable import MDEdCore

@Suite("FencedCodeTracker")
struct FencedCodeTrackerTests {

    @Test func noFenceEverythingOutside() {
        let lines = ["one", "two", "three"]
        #expect(FencedCodeTracker.linesInsideFence(lines) == [false, false, false])
    }

    @Test func backtickFenceMarksOpenAndCloseAndContentInside() {
        let lines = ["before", "```", "code", "```", "after"]
        #expect(FencedCodeTracker.linesInsideFence(lines) == [false, true, true, true, false])
    }

    @Test func tildeFenceWorksTheSameAsBacktick() {
        let lines = ["before", "~~~", "code", "~~~", "after"]
        #expect(FencedCodeTracker.linesInsideFence(lines) == [false, true, true, true, false])
    }

    @Test func openingFenceWithInfoStringIsRecognized() {
        let lines = ["```swift", "code", "```"]
        #expect(FencedCodeTracker.linesInsideFence(lines) == [true, true, true])
    }

    @Test func unclosedFenceStaysOpenToEndOfDocument() {
        let lines = ["```", "code", "still code"]
        #expect(FencedCodeTracker.linesInsideFence(lines) == [true, true, true])
    }

    @Test func closingFenceMustBeAtLeastAsLongAsOpening() {
        // A 4-backtick opener isn't closed by a 3-backtick line — it should still be "inside".
        let lines = ["````", "code with ``` inside", "```", "still inside", "````"]
        #expect(FencedCodeTracker.linesInsideFence(lines) == [true, true, true, true, true])
    }

    @Test func blankLinesInsideFenceAreStillInside() {
        let lines = ["```", "line one", "", "", "line two", "```"]
        #expect(FencedCodeTracker.linesInsideFence(lines) == [true, true, true, true, true, true])
    }

    @Test func twoSeparateFencesEachToggleIndependently() {
        let lines = ["```", "a", "```", "text", "```", "b", "```"]
        #expect(FencedCodeTracker.linesInsideFence(lines) == [true, true, true, false, true, true, true])
    }

    @Test func emptyInputProducesEmptyResult() {
        #expect(FencedCodeTracker.linesInsideFence([]).isEmpty)
    }
}
