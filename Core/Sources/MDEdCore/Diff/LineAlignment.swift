/// Maps a line position in one document of a diff to the corresponding fractional line position
/// in the other document, so a scroll-synced side-by-side view can keep two panes of different
/// lengths visually aligned.
///
/// ## Why fractional
///
/// The two documents almost never have the same number of lines. If pane A is scrolled so line
/// 143.0 (say, 40% down a wrapped line) is at the top, there is usually no line in pane B that is
/// *exactly* the equivalent position — the nearest anchor points (places where a line in A is
/// known to correspond to a specific line in B) bracket a stretch of pure insertions or removals
/// on one side. `LineAlignmentMap` reports where 143.0 falls *between* the bracketing anchors, as
/// a real number, so the caller can linearly interpolate a scroll offset instead of snapping to
/// the nearest whole line (which would visibly stutter as the user scrolls).
///
/// ## What counts as an anchor
///
/// An anchor is a `(left, right)` index pair known to correspond: every `.unchanged` diff entry
/// (both sides hold the same line) and every `.changed` diff entry (the lines differ, but they
/// were paired as replacing one another — see `diffLines(_:_:)`). `.removed` and `.inserted`
/// entries do not produce anchors, because they exist on only one side; they're exactly the
/// stretches interpolation has to cross. The document boundaries `(0, 0)` and
/// `(leftCount, rightCount)` are always implicit anchors, so every position in `[0, leftCount]`
/// maps to *some* position in `[0, rightCount]`, even before the first real anchor or after the
/// last (e.g. a document that starts with 20 lines of pure insertion before the first shared
/// line).
///
/// ## Judgment call
///
/// Nothing in `CollectionDifference` or the diff itself defines what "40% down a wrapped line"
/// or "half a line" means for scroll purposes — that's a UI-layer concept (line heights, wrapping,
/// font metrics). This type only promises the mapping is monotonic non-decreasing and piecewise
/// linear between anchors; the caller is expected to multiply the fractional part by whatever
/// their line-height/wrap model says a "line" is worth on screen.
public struct LineAlignmentMap: Sendable {
    /// One known-correspondence point between the two documents.
    private struct Anchor: Sendable {
        let left: Double
        let right: Double
    }

    /// Sorted, strictly-increasing-in-both-coordinates anchor points, always including the
    /// document start `(0, 0)` and end `(leftCount, rightCount)`.
    private let anchors: [Anchor]

    /// Builds an alignment map from a computed line diff.
    public init(_ result: LineDiffResult) {
        var pairs: [Anchor] = [Anchor(left: 0, right: 0)]
        for entry in result.entries {
            switch entry.kind {
            case .unchanged, .changed:
                if let l = entry.leftIndex, let r = entry.rightIndex {
                    pairs.append(Anchor(left: Double(l), right: Double(r)))
                }
            case .removed, .inserted:
                continue
            }
        }
        pairs.append(Anchor(left: Double(result.leftLines.count), right: Double(result.rightLines.count)))

        // De-duplicate and defensively enforce non-decreasing coordinates: the diff algorithm
        // already guarantees anchors are produced in increasing order on both sides, but this
        // keeps the invariant explicit and cheap to check rather than assumed.
        var deduped: [Anchor] = []
        for pair in pairs {
            if let last = deduped.last, last.left == pair.left, last.right == pair.right {
                continue
            }
            deduped.append(pair)
        }
        self.anchors = deduped
    }

    /// Given a (possibly fractional) line position in the left document, returns the
    /// corresponding fractional line position in the right document.
    public func position(ofLeft leftPosition: Double) -> Double {
        interpolate(leftPosition, from: \.left, to: \.right)
    }

    /// Given a (possibly fractional) line position in the right document, returns the
    /// corresponding fractional line position in the left document.
    public func position(ofRight rightPosition: Double) -> Double {
        interpolate(rightPosition, from: \.right, to: \.left)
    }

    private func interpolate(
        _ value: Double,
        from source: KeyPath<Anchor, Double>,
        to target: KeyPath<Anchor, Double>
    ) -> Double {
        guard !anchors.isEmpty else { return value }
        if value <= anchors[0][keyPath: source] {
            // Before (or at) the first anchor: extrapolate from the first segment if one exists,
            // otherwise there is nothing to scale against.
            guard anchors.count > 1 else { return anchors[0][keyPath: target] }
            let a = anchors[0]
            let b = anchors[1]
            return lerp(value, x0: a[keyPath: source], x1: b[keyPath: source], y0: a[keyPath: target], y1: b[keyPath: target])
        }
        if value >= anchors[anchors.count - 1][keyPath: source] {
            guard anchors.count > 1 else { return anchors[0][keyPath: target] }
            let a = anchors[anchors.count - 2]
            let b = anchors[anchors.count - 1]
            return lerp(value, x0: a[keyPath: source], x1: b[keyPath: source], y0: a[keyPath: target], y1: b[keyPath: target])
        }
        // Binary search for the bracketing pair of anchors.
        var lo = 0
        var hi = anchors.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if anchors[mid][keyPath: source] <= value {
                lo = mid
            } else {
                hi = mid
            }
        }
        let a = anchors[lo]
        let b = anchors[hi]
        return lerp(value, x0: a[keyPath: source], x1: b[keyPath: source], y0: a[keyPath: target], y1: b[keyPath: target])
    }

    private func lerp(_ x: Double, x0: Double, x1: Double, y0: Double, y1: Double) -> Double {
        guard x1 != x0 else { return y0 }
        let t = (x - x0) / (x1 - x0)
        return y0 + t * (y1 - y0)
    }
}
