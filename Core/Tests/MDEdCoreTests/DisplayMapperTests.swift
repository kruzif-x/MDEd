import Testing
@testable import MDEdCore

/// Exhaustive round-trip and boundary coverage for `DisplayMapper` — the piece the task brief
/// singles out as the dominant risk of live-preview hiding. Every test here is headless: no
/// `NSTextView`, no running app, just offsets in and offsets out.
@Suite("DisplayMapper")
struct DisplayMapperTests {

    // MARK: - Identity (no hidden ranges)

    @Test func identityPassesOffsetsThrough() {
        let mapper = DisplayMapper.identity(sourceLength: 20)
        #expect(mapper.displayLength == 20)
        for offset in 0...20 {
            #expect(mapper.displayOffset(forSource: offset) == offset)
            #expect(mapper.sourceOffset(forDisplay: offset) == offset)
        }
    }

    @Test func emptySourceNoHiddenRanges() {
        let mapper = DisplayMapper(sourceLength: 0, hiddenRanges: [])
        #expect(mapper.displayLength == 0)
        #expect(mapper.displayOffset(forSource: 0) == 0)
        #expect(mapper.sourceOffset(forDisplay: 0) == 0)
    }

    // MARK: - Single hidden range

    /// "0123456789", hiding [2, 5) — "01" + "56789" displayed, "234" collapsed.
    @Test func singleHiddenRangeInTheMiddle() {
        let mapper = DisplayMapper(sourceLength: 10, hiddenRanges: [TextRange(lowerBound: 2, upperBound: 5)])
        #expect(mapper.displayLength == 7)

        // Before the hidden range: identity.
        #expect(mapper.displayOffset(forSource: 0) == 0)
        #expect(mapper.displayOffset(forSource: 1) == 1)
        #expect(mapper.displayOffset(forSource: 2) == 2) // exactly at the hidden range's start

        // Strictly inside the hidden range: collapses to the same point as both boundaries.
        #expect(mapper.displayOffset(forSource: 3) == 2)
        #expect(mapper.displayOffset(forSource: 4) == 2)

        // Exactly at the hidden range's end, and beyond: shifted back by the hidden length (3).
        #expect(mapper.displayOffset(forSource: 5) == 2)
        #expect(mapper.displayOffset(forSource: 6) == 3)
        #expect(mapper.displayOffset(forSource: 9) == 6)
        #expect(mapper.displayOffset(forSource: 10) == 7)

        // Inverse at every reachable display offset round-trips to the first source offset that
        // maps to it (the boundary convention: display offset 2 is produced by both source 2 and
        // source 5, and the inverse must pick one consistently — the segment start, i.e. 5, since
        // that's where the *next* kept segment begins).
        for display in 0...7 {
            let source = mapper.sourceOffset(forDisplay: display)
            #expect(mapper.displayOffset(forSource: source) == display, "round trip failed at display \(display)")
        }
    }

    @Test func singleHiddenRangeAtStart() {
        let mapper = DisplayMapper(sourceLength: 10, hiddenRanges: [TextRange(lowerBound: 0, upperBound: 3)])
        #expect(mapper.displayLength == 7)
        #expect(mapper.displayOffset(forSource: 0) == 0)
        #expect(mapper.displayOffset(forSource: 1) == 0)
        #expect(mapper.displayOffset(forSource: 3) == 0)
        #expect(mapper.displayOffset(forSource: 4) == 1)
        #expect(mapper.sourceOffset(forDisplay: 0) == 3)
        #expect(mapper.sourceOffset(forDisplay: 1) == 4)
    }

    @Test func singleHiddenRangeAtEnd() {
        let mapper = DisplayMapper(sourceLength: 10, hiddenRanges: [TextRange(lowerBound: 7, upperBound: 10)])
        #expect(mapper.displayLength == 7)
        #expect(mapper.displayOffset(forSource: 6) == 6)
        #expect(mapper.displayOffset(forSource: 7) == 7)
        #expect(mapper.displayOffset(forSource: 8) == 7)
        #expect(mapper.displayOffset(forSource: 10) == 7)
        #expect(mapper.sourceOffset(forDisplay: 7) == 7) // last valid display offset
    }

    @Test func hiddenRangeSpanningTheEntireSource() {
        let mapper = DisplayMapper(sourceLength: 5, hiddenRanges: [TextRange(lowerBound: 0, upperBound: 5)])
        #expect(mapper.displayLength == 0)
        for offset in 0...5 {
            #expect(mapper.displayOffset(forSource: offset) == 0)
        }
        // Every source offset in [0, 5] maps to display 0 (the whole document is one hidden
        // run), so the inverse is inherently ambiguous — many source offsets share one display
        // point. The only property that must hold is the round trip back through the forward
        // direction, not any particular canonical source offset.
        let inverted = mapper.sourceOffset(forDisplay: 0)
        #expect(mapper.displayOffset(forSource: inverted) == 0)
    }

    // MARK: - Adjacent and overlapping hidden runs (must merge)

    @Test func adjacentHiddenRangesMergeIntoOne() {
        // "0123456789", hiding [2,4) and [4,6) — touching, must behave as one [2,6) run.
        let mapper = DisplayMapper(sourceLength: 10, hiddenRanges: [
            TextRange(lowerBound: 2, upperBound: 4),
            TextRange(lowerBound: 4, upperBound: 6),
        ])
        #expect(mapper.displayLength == 6)
        #expect(mapper.displayOffset(forSource: 2) == 2)
        #expect(mapper.displayOffset(forSource: 3) == 2)
        #expect(mapper.displayOffset(forSource: 4) == 2) // the shared boundary
        #expect(mapper.displayOffset(forSource: 5) == 2)
        #expect(mapper.displayOffset(forSource: 6) == 2)
        #expect(mapper.displayOffset(forSource: 7) == 3)
    }

    @Test func overlappingHiddenRangesMerge() {
        let mapper = DisplayMapper(sourceLength: 10, hiddenRanges: [
            TextRange(lowerBound: 2, upperBound: 6),
            TextRange(lowerBound: 4, upperBound: 8),
        ])
        // Merged to [2, 8) — length 6 hidden.
        #expect(mapper.displayLength == 4)
        #expect(mapper.displayOffset(forSource: 8) == 2)
        #expect(mapper.displayOffset(forSource: 9) == 3)
    }

    @Test func hiddenRangesGivenOutOfOrderMergeIdenticallyToInOrder() {
        let outOfOrder = DisplayMapper(sourceLength: 20, hiddenRanges: [
            TextRange(lowerBound: 15, upperBound: 18),
            TextRange(lowerBound: 2, upperBound: 5),
            TextRange(lowerBound: 8, upperBound: 10),
        ])
        let inOrder = DisplayMapper(sourceLength: 20, hiddenRanges: [
            TextRange(lowerBound: 2, upperBound: 5),
            TextRange(lowerBound: 8, upperBound: 10),
            TextRange(lowerBound: 15, upperBound: 18),
        ])
        for offset in 0...20 {
            #expect(outOfOrder.displayOffset(forSource: offset) == inOrder.displayOffset(forSource: offset))
        }
    }

    // MARK: - Non-adjacent multiple hidden runs

    @Test func twoSeparateHiddenRunsWithAGapBetween() {
        // "0123456789", hiding [1,3) and [6,8) — kept: "0", "345", "89".
        let mapper = DisplayMapper(sourceLength: 10, hiddenRanges: [
            TextRange(lowerBound: 1, upperBound: 3),
            TextRange(lowerBound: 6, upperBound: 8),
        ])
        #expect(mapper.displayLength == 6)
        let expected: [Int: Int] = [0: 0, 1: 1, 2: 1, 3: 1, 4: 2, 5: 3, 6: 4, 7: 4, 8: 4, 9: 5, 10: 6]
        for (source, display) in expected {
            #expect(mapper.displayOffset(forSource: source) == display, "source \(source)")
        }
        for display in 0...6 {
            let source = mapper.sourceOffset(forDisplay: display)
            #expect(mapper.displayOffset(forSource: source) == display)
        }
    }

    // MARK: - Nested-emphasis-shaped ranges (multiple small hidden runs, like "**bold *em* bold**")

    @Test func manySmallHiddenMarkersLikeNestedEmphasis() {
        // "**bold *em* bold**" — 18 chars. Hidden: [0,2) "**", [7,8) "*", [10,11) "*", [16,18) "**".
        let source = "**bold *em* bold**"
        #expect(source.utf16.count == 19 - 1) // sanity: literal length check below is what matters
        let hidden = [
            TextRange(lowerBound: 0, upperBound: 2),
            TextRange(lowerBound: 7, upperBound: 8),
            TextRange(lowerBound: 10, upperBound: 11),
            TextRange(lowerBound: 16, upperBound: 18),
        ]
        let mapper = DisplayMapper(sourceLength: source.utf16.count, hiddenRanges: hidden)
        let expectedHiddenLength = 2 + 1 + 1 + 2
        #expect(mapper.displayLength == source.utf16.count - expectedHiddenLength)

        // Every *display* offset round-trips through source and back to itself — the direction
        // that's always unambiguous (see `DisplayMapper`'s doc comment: multiple source offsets,
        // including a hidden range's own boundaries, can legitimately share one display point, so
        // source -> display -> source is not guaranteed to return the original source offset, only
        // display -> source -> display is).
        for display in 0...mapper.displayLength {
            let source = mapper.sourceOffset(forDisplay: display)
            #expect(mapper.displayOffset(forSource: source) == display, "display offset \(display) failed to round-trip")
        }
    }

    // MARK: - Substituted-marker-shaped ranges (a multi-unit kept prefix, not one)

    /// The app target's live-preview list-bullet substitution keeps a *prefix* of the marker long
    /// enough to hold the glyph it stands in for (`"• "`, two units) and hides only what's left —
    /// unlike every other hidden-range shape in this file, where the kept segment right before a
    /// hidden run is always the *unmodified* source text. `DisplayMapper` itself never sees the
    /// glyph (it only ever deals in range lengths, never replacement content), so this is really
    /// checking that a two-unit-then-hidden shape behaves exactly like the existing one-unit case,
    /// just with the boundary moved over by one — not a new code path, but worth pinning down
    /// explicitly since it's the shape a substituted-marker's `rebuildMapper()` actually produces.
    /// "- item\n" (task marker `"- "` fully kept, nothing hidden) is covered implicitly by every
    /// zero-hidden-range case above; this covers the *task-list* marker `"- [ ] "` (6 units), where
    /// only the first 2 (`"- "`, standing in for `"☐ "`) are kept and the remaining 4 (`"[ ] "`)
    /// are hidden.
    @Test func substitutedMarkerTwoUnitKeptPrefixThenHiddenRest() {
        // "- [ ] todo" — marker is "- [ ] " (units 0..<6), kept prefix is 2 units (0..<2, standing
        // in for "☐ "), hidden rest is 4 units (2..<6, "[ ] "). Content "todo" follows at unit 6.
        let source = "- [ ] todo"
        #expect(source.utf16.count == 10)
        let mapper = DisplayMapper(sourceLength: 10, hiddenRanges: [TextRange(lowerBound: 2, upperBound: 6)])
        #expect(mapper.displayLength == 6) // "- " (2, kept) + "todo" (4) — "[ ] " (4) hidden

        // The kept prefix passes through unchanged, same as any kept segment.
        #expect(mapper.displayOffset(forSource: 0) == 0)
        #expect(mapper.displayOffset(forSource: 1) == 1)
        #expect(mapper.displayOffset(forSource: 2) == 2) // exactly at the hidden run's start

        // Inside the hidden run: collapses to the run's single display point, same convention as
        // every other hidden range in this file.
        #expect(mapper.displayOffset(forSource: 3) == 2)
        #expect(mapper.displayOffset(forSource: 4) == 2)
        #expect(mapper.displayOffset(forSource: 5) == 2)

        // Content after the hidden run resumes right where the kept prefix left off.
        #expect(mapper.displayOffset(forSource: 6) == 2)
        #expect(mapper.displayOffset(forSource: 10) == 6)

        // Full round trip in the only direction that's guaranteed unambiguous.
        for display in 0...mapper.displayLength {
            let src = mapper.sourceOffset(forDisplay: display)
            #expect(mapper.displayOffset(forSource: src) == display, "display offset \(display) failed to round-trip")
        }

        // The kept two-unit prefix is never reported as "hidden" — this is what would let the app
        // target safely swap its *displayed text* (to "☐ ") without `DisplayMapper` ever being
        // asked to collapse it.
        #expect(!mapper.isHidden(source: 0))
        #expect(!mapper.isHidden(source: 1))
    }

    // MARK: - Non-ASCII: UTF-16 offsets, not Character or UTF-8 byte offsets

    /// "a👍b" — 'a' (1 UTF-16 unit), 👍 U+1F44D (2 UTF-16 units, surrogate pair), 'b' (1 unit).
    /// Hiding the emoji (a 2-unit hidden range) must not split a surrogate pair's own two units
    /// across the hidden/kept boundary.
    @Test func emojiSurrogatePairAsHiddenRange() {
        let source = "a👍b"
        #expect(source.utf16.count == 4)
        let mapper = DisplayMapper(sourceLength: 4, hiddenRanges: [TextRange(lowerBound: 1, upperBound: 3)])
        #expect(mapper.displayLength == 2) // "a" + "b"
        #expect(mapper.displayOffset(forSource: 0) == 0) // before 'a'... actually 'a' itself
        #expect(mapper.displayOffset(forSource: 1) == 1) // right after 'a', at the emoji's start
        #expect(mapper.displayOffset(forSource: 2) == 1) // mid-surrogate-pair: collapses, same as boundaries
        #expect(mapper.displayOffset(forSource: 3) == 1) // right after the emoji
        #expect(mapper.displayOffset(forSource: 4) == 2) // after 'b'
        #expect(mapper.sourceOffset(forDisplay: 0) == 0)
        #expect(mapper.sourceOffset(forDisplay: 1) == 3)
        #expect(mapper.sourceOffset(forDisplay: 2) == 4)
    }

    /// CJK text has no UTF-8/UTF-16 length surprises (each character is exactly 1 UTF-16 unit),
    /// but is included since it's explicitly called out as a class of input to verify against.
    @Test func cjkTextHiddenRange() {
        let source = "日本語のテスト" // 7 characters, 7 UTF-16 units
        #expect(source.utf16.count == 7)
        let mapper = DisplayMapper(sourceLength: 7, hiddenRanges: [TextRange(lowerBound: 2, upperBound: 4)])
        #expect(mapper.displayLength == 5)
        #expect(mapper.displayOffset(forSource: 2) == 2)
        #expect(mapper.displayOffset(forSource: 3) == 2)
        #expect(mapper.displayOffset(forSource: 4) == 2)
        #expect(mapper.displayOffset(forSource: 7) == 5)
    }

    /// "é" as 'e' + U+0301 COMBINING ACUTE ACCENT is 1 grapheme cluster (`Character`) but 2
    /// Unicode scalars and 2 UTF-16 code units — exactly the discrepancy `TextRange`'s
    /// documentation warns about. A hidden range that clips only the combining mark (not the base
    /// character) must still resolve to sane, non-crashing offsets.
    @Test func combiningCharacterAsPartialHiddenRange() {
        let source = "e\u{0301}x" // "é" (2 UTF-16 units) + "x"
        #expect(source.utf16.count == 3)
        let mapper = DisplayMapper(sourceLength: 3, hiddenRanges: [TextRange(lowerBound: 1, upperBound: 2)]) // just the combining mark
        #expect(mapper.displayLength == 2)
        #expect(mapper.displayOffset(forSource: 0) == 0)
        #expect(mapper.displayOffset(forSource: 1) == 1)
        #expect(mapper.displayOffset(forSource: 2) == 1)
        #expect(mapper.displayOffset(forSource: 3) == 2)
    }

    // MARK: - Out-of-bounds and degenerate inputs (must clamp, never trap)

    @Test func offsetsPastSourceLengthClamp() {
        let mapper = DisplayMapper(sourceLength: 5, hiddenRanges: [TextRange(lowerBound: 1, upperBound: 2)])
        #expect(mapper.displayOffset(forSource: 1000) == mapper.displayOffset(forSource: 5))
        #expect(mapper.displayOffset(forSource: -50) == mapper.displayOffset(forSource: 0))
        #expect(mapper.sourceOffset(forDisplay: 1000) == mapper.sourceOffset(forDisplay: mapper.displayLength))
        #expect(mapper.sourceOffset(forDisplay: -50) == mapper.sourceOffset(forDisplay: 0))
    }

    @Test func hiddenRangeExtendingPastSourceLengthClamps() {
        let mapper = DisplayMapper(sourceLength: 5, hiddenRanges: [TextRange(lowerBound: 3, upperBound: 100)])
        #expect(mapper.displayLength == 3)
        #expect(mapper.sourceLength == 5)
    }

    @Test func zeroLengthHiddenRangeIsANoOp() {
        let mapper = DisplayMapper(sourceLength: 10, hiddenRanges: [TextRange(lowerBound: 4, upperBound: 4)])
        #expect(mapper.displayLength == 10)
        for offset in 0...10 {
            #expect(mapper.displayOffset(forSource: offset) == offset)
        }
    }

    @Test func noHiddenRangesOnEmptySource() {
        let mapper = DisplayMapper(sourceLength: 0, hiddenRanges: [TextRange(lowerBound: 0, upperBound: 0)])
        #expect(mapper.displayLength == 0)
        #expect(mapper.displayOffset(forSource: 0) == 0)
    }

    // MARK: - Range conversion helpers

    @Test func displayRangeAndSourceRangeRoundTripForAKeptRange() {
        let mapper = DisplayMapper(sourceLength: 10, hiddenRanges: [TextRange(lowerBound: 2, upperBound: 4)])
        let sourceRange = TextRange(lowerBound: 5, upperBound: 8)
        let displayRange = mapper.displayRange(forSource: sourceRange)
        #expect(displayRange == TextRange(lowerBound: 3, upperBound: 6))
        #expect(mapper.sourceRange(forDisplay: displayRange) == sourceRange)
    }

    @Test func displayRangeForARangeEntirelyInsideAHiddenRunCollapsesToZeroLength() {
        let mapper = DisplayMapper(sourceLength: 10, hiddenRanges: [TextRange(lowerBound: 2, upperBound: 6)])
        let displayRange = mapper.displayRange(forSource: TextRange(lowerBound: 3, upperBound: 5))
        #expect(displayRange.isEmpty)
        #expect(displayRange.lowerBound == 2)
    }

    @Test func displayRangeStraddlingAHiddenRunExcludesItsLength() {
        let mapper = DisplayMapper(sourceLength: 10, hiddenRanges: [TextRange(lowerBound: 4, upperBound: 6)])
        // Source [2, 8) straddles the hidden [4,6) run entirely.
        let displayRange = mapper.displayRange(forSource: TextRange(lowerBound: 2, upperBound: 8))
        #expect(displayRange.length == 4) // 6 source chars minus 2 hidden
    }

    // MARK: - isHidden(source:)

    @Test func isHiddenReportsStrictInteriorOnly() {
        let mapper = DisplayMapper(sourceLength: 10, hiddenRanges: [TextRange(lowerBound: 3, upperBound: 6)])
        #expect(!mapper.isHidden(source: 2))
        #expect(!mapper.isHidden(source: 3)) // boundary — not "inside"
        #expect(mapper.isHidden(source: 4))
        #expect(mapper.isHidden(source: 5))
        #expect(!mapper.isHidden(source: 6)) // boundary
        #expect(!mapper.isHidden(source: 7))
    }

    // MARK: - Exhaustive brute-force cross-check against a naive reference implementation

    /// A deliberately naive, obviously-correct-by-inspection reference: walk every source offset
    /// one at a time and count how many *kept* offsets precede it. Slow (`O(n)` per query, `O(n²)`
    /// total) but trivially verifiable by eye, unlike the binary-search implementation under test.
    /// Run across many random hidden-range configurations so the fast implementation's boundary
    /// arithmetic has nowhere to hide a one-off error.
    @Test func bruteForceCrossCheckAcrossRandomConfigurations() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        for _ in 0..<200 {
            let length = Int(rng.next(upperBound: 40))
            var ranges: [TextRange] = []
            let rangeCount = Int(rng.next(upperBound: 6))
            for _ in 0..<rangeCount {
                guard length > 0 else { break }
                let a = Int(rng.next(upperBound: UInt64(length + 1)))
                let b = Int(rng.next(upperBound: UInt64(length + 1)))
                ranges.append(TextRange(lowerBound: min(a, b), upperBound: max(a, b)))
            }
            let mapper = DisplayMapper(sourceLength: length, hiddenRanges: ranges)

            func isSourceHidden(_ o: Int) -> Bool {
                ranges.contains { $0.lowerBound <= o && o < $0.upperBound }
            }
            func naiveDisplayOffset(_ o: Int) -> Int {
                (0..<o).filter { !isSourceHidden($0) }.count
            }

            for o in 0...length {
                #expect(mapper.displayOffset(forSource: o) == naiveDisplayOffset(o), "length \(length) ranges \(ranges) offset \(o)")
            }
            // Every display offset inverts to *some* source offset whose own display offset matches.
            for d in 0...mapper.displayLength {
                let s = mapper.sourceOffset(forDisplay: d)
                #expect(mapper.displayOffset(forSource: s) == d, "length \(length) ranges \(ranges) display \(d) -> source \(s)")
            }
        }
    }
}

/// A tiny deterministic PRNG (SplitMix64) so the brute-force cross-check above is reproducible —
/// no dependency on `Foundation`'s `SystemRandomNumberGenerator`, which is intentionally
/// non-reproducible across runs.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next(upperBound: UInt64) -> UInt64 {
        guard upperBound > 0 else { return 0 }
        return next() % upperBound
    }
}
