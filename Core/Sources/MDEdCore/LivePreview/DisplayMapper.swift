/// A bidirectional mapping between offsets in a document's **source** text (what's on disk, what
/// undo/autosave/find operate on) and offsets in its **display** text (what live-preview editing
/// actually shows, with some source ranges — hidden Markdown markers — elided to zero width).
///
/// This is the single place range translation for live-preview hiding happens. Every other
/// coordinate a display-transformed text view needs to reason about (click location, selection,
/// arrow-key motion, find results, the line-number gutter, word count) is expressed in one of
/// these two spaces, and every conversion between them goes through here rather than being
/// reimplemented ad hoc at each call site — see the app target's `LivePreviewController` for the
/// call sites.
///
/// ## The collapsing convention
///
/// A hidden range contributes **zero** length to the display text: source offsets `lowerBound`
/// and `upperBound` of a hidden range, and every offset strictly between them, all map to the
/// *same* display offset — the point where the collapsed run sits. This is deliberate and
/// consistent rather than picking a side: a source offset landing inside a hidden run (e.g. an
/// undo operation restoring a caret position that predates the run becoming hidden) has no
/// meaningful display position of its own, so it snaps to the run's collapse point rather than to
/// an arbitrary edge.
///
/// ## Complexity
///
/// Built once in `O(n)` (`n` = number of hidden ranges, after merging overlapping/adjacent ones).
/// Both directions resolve in `O(log n)` via binary search over precomputed segment boundaries.
public struct DisplayMapper: Sendable, Equatable {

    /// One maximal run of source text that survives into the display text unmodified: `source`
    /// gives its UTF-16 bounds in the source string, `displayStart` the UTF-16 offset in the
    /// display string where it begins (its length is identical in both spaces, since nothing
    /// inside a kept segment is hidden).
    private struct KeptSegment: Sendable, Equatable {
        let sourceStart: Int
        let sourceEnd: Int
        let displayStart: Int
        var length: Int { sourceEnd - sourceStart }
    }

    /// Hidden ranges in source coordinates: sorted ascending, merged so no two overlap or touch.
    private let hidden: [TextRange]

    /// Kept segments, in both source and display coordinates, sorted ascending in both (a kept
    /// segment's relative order is identical in source and display space — hiding removes text,
    /// it never reorders it). Always has at least one entry, possibly zero-length, mirroring
    /// `DocumentLines`' and `LineOffsetTable`'s "always at least one" convention so offset 0 in an
    /// entirely-hidden or empty document still resolves.
    private let segments: [KeptSegment]

    /// The length, in UTF-16 code units, of the source text this mapper was built from.
    public let sourceLength: Int

    /// The length, in UTF-16 code units, of the resulting display text — `sourceLength` minus the
    /// total length of every (merged) hidden range.
    public let displayLength: Int

    /// Builds a mapper for a source text of `sourceLength` UTF-16 code units, hiding
    /// `hiddenRanges` (in source coordinates). Ranges may be given in any order, may overlap, and
    /// may extend past `sourceLength` — all three are normalized (sorted, merged, clamped) rather
    /// than trapped on, since this is expected to be built from live parse output on every
    /// keystroke and should degrade gracefully on a transient inconsistency instead of crashing
    /// the editor.
    public init(sourceLength: Int, hiddenRanges: [TextRange]) {
        let sourceLength = max(0, sourceLength)
        self.sourceLength = sourceLength

        let normalized = hiddenRanges
            .map { range -> TextRange in
                let lower = min(max(range.lowerBound, 0), sourceLength)
                let upper = min(max(range.upperBound, 0), sourceLength)
                return TextRange(lowerBound: min(lower, upper), upperBound: max(lower, upper))
            }
            .filter { $0.length > 0 }
            .sorted { $0.lowerBound < $1.lowerBound }

        var merged: [TextRange] = []
        for range in normalized {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = TextRange(
                    lowerBound: last.lowerBound,
                    upperBound: max(last.upperBound, range.upperBound)
                )
            } else {
                merged.append(range)
            }
        }
        self.hidden = merged

        var segments: [KeptSegment] = []
        var sourceCursor = 0
        var displayCursor = 0
        for range in merged {
            if range.lowerBound > sourceCursor {
                segments.append(KeptSegment(sourceStart: sourceCursor, sourceEnd: range.lowerBound, displayStart: displayCursor))
                displayCursor += range.lowerBound - sourceCursor
            }
            sourceCursor = range.upperBound
        }
        if sourceCursor < sourceLength || segments.isEmpty {
            segments.append(KeptSegment(sourceStart: sourceCursor, sourceEnd: sourceLength, displayStart: displayCursor))
        }
        self.segments = segments
        self.displayLength = merged.reduce(sourceLength) { $0 - $1.length }
    }

    /// A mapper with no hidden ranges at all — display text is source text, offsets pass through
    /// unchanged. The identity element; equivalent to hiding being turned off.
    public static func identity(sourceLength: Int) -> DisplayMapper {
        DisplayMapper(sourceLength: sourceLength, hiddenRanges: [])
    }

    // MARK: - Source → display

    /// Converts a source UTF-16 offset to its display UTF-16 offset. Offsets outside
    /// `0...sourceLength` are clamped. An offset inside a hidden run collapses to that run's
    /// single display point — see this type's documentation.
    public func displayOffset(forSource source: Int) -> Int {
        let clamped = min(max(source, 0), sourceLength)
        let index = segmentIndex(atOrBeforeSource: clamped)
        let segment = segments[index]
        if clamped < segment.sourceStart {
            // `segmentIndex(atOrBeforeSource:)` returns index 0 even when *no* segment actually
            // starts at or before `clamped` — e.g. the entire document is hidden, so the one
            // (zero-length) segment sits at `sourceStart == sourceLength`, past every real
            // offset. `clamped` is inside the hidden run *before* this segment; collapse to its
            // start, same as any other "inside a hidden run" case.
            return segment.displayStart
        }
        if clamped <= segment.sourceEnd {
            return segment.displayStart + (clamped - segment.sourceStart)
        }
        // `clamped` falls strictly inside the hidden run right after this segment — collapse to
        // this segment's own end, which is numerically identical to the following segment's start
        // (both bound the same zero-width hidden run in display space).
        return segment.displayStart + segment.length
    }

    /// Converts a source `TextRange` to its display `TextRange`. A range entirely inside a hidden
    /// run collapses to a zero-length range at that run's display point; a range that straddles a
    /// hidden run keeps everything on both sides, with the hidden middle contributing nothing to
    /// its display length.
    public func displayRange(forSource range: TextRange) -> TextRange {
        TextRange(lowerBound: displayOffset(forSource: range.lowerBound), upperBound: displayOffset(forSource: range.upperBound))
    }

    // MARK: - Display → source

    /// Converts a display UTF-16 offset back to its source UTF-16 offset. Every display offset
    /// corresponds to exactly one source offset (display text contains no hidden content, so
    /// there is nothing to collapse in this direction).
    public func sourceOffset(forDisplay display: Int) -> Int {
        let clamped = min(max(display, 0), displayLength)
        let index = segmentIndex(atOrBeforeDisplay: clamped)
        let segment = segments[index]
        return segment.sourceStart + (clamped - segment.displayStart)
    }

    /// Converts a display `TextRange` to its source `TextRange`.
    public func sourceRange(forDisplay range: TextRange) -> TextRange {
        TextRange(lowerBound: sourceOffset(forDisplay: range.lowerBound), upperBound: sourceOffset(forDisplay: range.upperBound))
    }

    // MARK: - Queries

    /// `true` if `source` falls strictly inside one of the hidden ranges this mapper was built
    /// from (not merely touching a boundary).
    public func isHidden(source: Int) -> Bool {
        let index = segmentIndex(atOrBeforeSource: min(max(source, 0), sourceLength))
        let segment = segments[index]
        return source > segment.sourceEnd && source < (index + 1 < segments.count ? segments[index + 1].sourceStart : sourceLength + 1)
    }

    // MARK: - Binary search

    /// The index of the last segment whose `sourceStart <= source` (segments are sorted ascending
    /// and disjoint, so this is well-defined for any `source` in `0...sourceLength`).
    private func segmentIndex(atOrBeforeSource source: Int) -> Int {
        var lo = 0
        var hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].sourceStart <= source {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    /// The index of the last segment whose `displayStart <= display`.
    private func segmentIndex(atOrBeforeDisplay display: Int) -> Int {
        var lo = 0
        var hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].displayStart <= display {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }
}
