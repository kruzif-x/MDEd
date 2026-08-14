/// Maps a vertical scroll offset (in points, measured from the top of the document) in one pane
/// of a two-document comparison to the corresponding offset in the other pane, so a scroll-synced
/// side-by-side view tracks visually rather than just line-index-for-line-index.
///
/// `LineAlignmentMap` maps fractional *line* positions between documents but deliberately says
/// nothing about points — "line height and wrapping are yours to apply" (see its documentation).
/// This type is that application: given each pane's actual per-line rendered height (which varies
/// with word wrap, so it is not a caller-supplied constant), it converts a point offset to a
/// fractional line position, asks `LineAlignmentMap` for the corresponding fractional line
/// position on the other side, then converts that back to a point offset using the other side's
/// line heights.
public struct ScrollOffsetMapper: Sendable {
    private let alignment: LineAlignmentMap
    /// `leftCumulative[i]` is the y-offset of the *top* of left line `i`; the array has
    /// `leftLineHeights.count + 1` entries, the last being the document's total height.
    private let leftCumulative: [Double]
    private let rightCumulative: [Double]
    private let leftLineHeights: [Double]
    private let rightLineHeights: [Double]

    /// - Parameters:
    ///   - alignment: the line-level alignment between the two documents.
    ///   - leftLineHeights: the rendered height, in points, of each line of the left document, in
    ///     order. May be empty (an empty document).
    ///   - rightLineHeights: likewise for the right document.
    public init(alignment: LineAlignmentMap, leftLineHeights: [Double], rightLineHeights: [Double]) {
        self.alignment = alignment
        self.leftLineHeights = leftLineHeights
        self.rightLineHeights = rightLineHeights
        self.leftCumulative = Self.cumulative(leftLineHeights)
        self.rightCumulative = Self.cumulative(rightLineHeights)
    }

    private static func cumulative(_ heights: [Double]) -> [Double] {
        var result: [Double] = [0]
        result.reserveCapacity(heights.count + 1)
        var running = 0.0
        for height in heights {
            running += height
            result.append(running)
        }
        return result
    }

    /// Given a y-offset (points from the top) in the left document, returns the corresponding
    /// y-offset in the right document.
    public func rightOffset(forLeftOffset leftOffset: Double) -> Double {
        let fractionalLeftLine = fractionalLine(forOffset: leftOffset, cumulative: leftCumulative, heights: leftLineHeights)
        let fractionalRightLine = alignment.position(ofLeft: fractionalLeftLine)
        return offset(forFractionalLine: fractionalRightLine, cumulative: rightCumulative, heights: rightLineHeights)
    }

    /// Given a y-offset (points from the top) in the right document, returns the corresponding
    /// y-offset in the left document.
    public func leftOffset(forRightOffset rightOffset: Double) -> Double {
        let fractionalRightLine = fractionalLine(forOffset: rightOffset, cumulative: rightCumulative, heights: rightLineHeights)
        let fractionalLeftLine = alignment.position(ofRight: fractionalRightLine)
        return offset(forFractionalLine: fractionalLeftLine, cumulative: leftCumulative, heights: leftLineHeights)
    }

    // MARK: - Offset <-> fractional line

    /// Converts a y-offset into a fractional line position: the integer part is the line index,
    /// the fractional part is how far through that line's height the offset falls.
    private func fractionalLine(forOffset offset: Double, cumulative: [Double], heights: [Double]) -> Double {
        guard !heights.isEmpty else { return 0 }
        let totalHeight = cumulative[cumulative.count - 1]
        let clamped = min(max(offset, 0), totalHeight)

        // Binary search for the line whose [start, start+height) span contains `clamped`.
        var lo = 0
        var hi = heights.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cumulative[mid] <= clamped {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        let lineStart = cumulative[lo]
        let height = heights[lo]
        let fraction = height > 0 ? (clamped - lineStart) / height : 0
        return Double(lo) + fraction
    }

    /// The inverse of `fractionalLine(forOffset:cumulative:heights:)`.
    private func offset(forFractionalLine fractionalLine: Double, cumulative: [Double], heights: [Double]) -> Double {
        guard !heights.isEmpty else { return 0 }
        let lastIndex = heights.count - 1
        let clampedLine = min(max(fractionalLine, 0), Double(heights.count))
        var lineIndex = Int(clampedLine)
        var fraction = clampedLine - Double(lineIndex)
        if lineIndex > lastIndex {
            lineIndex = lastIndex
            fraction = 1
        }
        return cumulative[lineIndex] + fraction * heights[lineIndex]
    }
}
