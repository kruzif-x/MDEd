import Foundation

/// A half-open range of UTF-16 code unit offsets into some text.
///
/// `AppKit`'s `NSTextStorage` (and `NSAttributedString`, `NSRange`, etc.) all
/// address text in UTF-16 code units, not `Character`s ("extended grapheme
/// clusters") and not UTF-8 bytes. Every range MDEdCore hands back to a
/// future UI layer is expressed in this unit so it can be handed to
/// `NSRange(location:length:)` without any further conversion — and so it
/// never silently drifts off by one on the boundary of an emoji, a CJK
/// character, or a combining mark, all of which have UTF-16 lengths that
/// differ from their UTF-8 byte length or their `Character` count of 1.
///
/// `TextRange` intentionally stores plain `Int` offsets rather than
/// `String.Index` so it is `Sendable`, comparable across two different
/// `String` values (e.g. a "before" and "after" document in the diff
/// engine), and trivially convertible to `NSRange`.
public struct TextRange: Sendable, Hashable {
    /// The UTF-16 offset of the first code unit in the range.
    public var lowerBound: Int

    /// The UTF-16 offset one past the last code unit in the range (i.e. the range is `[lowerBound, upperBound)`).
    public var upperBound: Int

    /// Creates a range from explicit UTF-16 bounds.
    ///
    /// - Precondition: `lowerBound <= upperBound`.
    public init(lowerBound: Int, upperBound: Int) {
        precondition(lowerBound <= upperBound, "TextRange lowerBound must not exceed upperBound")
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// Creates a range from a standard library `Range<Int>` of UTF-16 offsets.
    public init(_ range: Range<Int>) {
        self.init(lowerBound: range.lowerBound, upperBound: range.upperBound)
    }

    /// The number of UTF-16 code units spanned by this range.
    public var length: Int { upperBound - lowerBound }

    /// `true` when the range spans zero code units.
    public var isEmpty: Bool { lowerBound == upperBound }

    /// The smallest range that contains both `self` and `other`.
    public func union(_ other: TextRange) -> TextRange {
        TextRange(lowerBound: Swift.min(lowerBound, other.lowerBound), upperBound: Swift.max(upperBound, other.upperBound))
    }

    /// This range expressed as a standard library `Range<Int>`, for callers that prefer that currency type.
    public var range: Range<Int> { lowerBound..<upperBound }

    /// This range expressed as `Foundation.NSRange`, ready to hand to `NSTextStorage`,
    /// `NSAttributedString`, or any other AppKit/UIKit text API — all of which already
    /// address text in UTF-16 code units, exactly what this type stores.
    public var nsRange: NSRange { NSRange(location: lowerBound, length: length) }
}

extension TextRange: CustomStringConvertible {
    public var description: String { "\(lowerBound)..<\(upperBound)" }
}
