import Foundation
import Testing
@testable import MDEdCore

@Suite("MarkupComparator")
struct MarkupComparatorTests {

    @Test func markupAddedByTheModelIsReported() {
        // The observed failure mode this exists to catch: the model wraps plain words in `**bold**`
        // that the source never had.
        let source = "Plain words, nothing fancy here."
        let result = "Plain **words**, nothing fancy here."
        let delta = MarkupComparator.delta(source: source, result: result)
        #expect(delta.hasChanges)
        #expect(delta.introduced == [.strong])
    }

    @Test func markupRemovedByTheModelIsNotReported() {
        // This type only ever flags additions — see its own doc comment for why removal is a
        // different (unhandled) failure mode.
        let source = "This has **bold** text in it."
        let result = "This has bold text in it."
        let delta = MarkupComparator.delta(source: source, result: result)
        #expect(!delta.hasChanges)
        #expect(delta.introduced.isEmpty)
    }

    @Test func unchangedMarkupIsNotReported() {
        let source = "A **bold** word and an _emphasized_ one, plus `code`."
        let result = "A **bold** word and an _emphasized_ one, plus `code`, reworded slightly."
        let delta = MarkupComparator.delta(source: source, result: result)
        #expect(!delta.hasChanges)
    }

    @Test func nestedEmphasisIsCountedPerKindNotPerOccurrence() {
        // Two new `strong` runs, one of which nests an `emphasis` run inside it — `introduced`
        // reports each *kind* once, not once per occurrence (see `MarkupDelta.introduced`'s own doc
        // comment), so this should report exactly `[.strong, .emphasis]`, not four entries.
        let source = "Plain sentence with no markup at all in it whatsoever."
        let result = "Plain **sentence** with **no _markup_** at all in it whatsoever."
        let delta = MarkupComparator.delta(source: source, result: result)
        #expect(Set(delta.introduced) == Set([.strong, .emphasis]))
        #expect(delta.introduced.count == 2)
    }

    @Test func nonASCIIContentIsComparedCorrectly() {
        // Non-ASCII (here CJK + emoji, both multi-UTF-16-unit-sensitive) shouldn't confuse the
        // underlying UTF-16 range bookkeeping `syntaxMap(of:)` relies on.
        let source = "这是一段没有加粗的中文文字 🎉 完全没有格式。"
        let result = "这是一段**加粗的**中文文字 🎉 完全没有格式。"
        let delta = MarkupComparator.delta(source: source, result: result)
        #expect(delta.introduced == [.strong])
    }

    @Test func identicalTextHasNoDelta() {
        let text = "# Title\n\nSome **bold** and _emphasized_ text, plus a [link](https://example.com)."
        let delta = MarkupComparator.delta(source: text, result: text)
        #expect(!delta.hasChanges)
        #expect(delta.introduced.isEmpty)
    }

    @Test func headingLevelChangeCountsAsADistinctKind() {
        // `SyntaxKind.heading(level:)` carries its level as associated data, so a `##` becoming a
        // `#` (or vice versa) is a different dictionary key entirely — `delta` reports it as the
        // new level appearing where it didn't before, which is the correct read: the result does
        // contain heading markup the source didn't have, just not at the same depth.
        let source = "## Section\n\nBody text."
        let result = "# Section\n\nBody text."
        let delta = MarkupComparator.delta(source: source, result: result)
        #expect(delta.introduced == [.heading(level: 1)])
    }
}
