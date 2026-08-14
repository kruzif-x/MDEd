/// The classification of one token in a word-level diff of a single changed line.
public enum WordDiffKind: Sendable, Equatable, Hashable {
    case unchanged
    case removed
    case inserted
}

/// One token of a word-level diff, with its range (in UTF-16 offsets, as `TextRange`) within the
/// *single line string it came from* — not within any larger document. Callers that need a
/// document-absolute range should add the line's own starting offset.
public struct WordDiffSpan: Sendable, Equatable {
    public let kind: WordDiffKind
    public let range: TextRange
    public let text: Substring

    public init(kind: WordDiffKind, range: TextRange, text: Substring) {
        self.kind = kind
        self.range = range
        self.text = text
    }
}

/// The result of a word-level diff between one "before" line and one "after" line: two span
/// lists, one per side, that together let a UI underline or highlight only the text that
/// actually differs instead of the whole line.
public struct WordDiffResult: Sendable, Equatable {
    /// Spans tiling `oldLine` completely, tagged `.unchanged` or `.removed`.
    public let oldSpans: [WordDiffSpan]
    /// Spans tiling `newLine` completely, tagged `.unchanged` or `.inserted`.
    public let newSpans: [WordDiffSpan]

    public init(oldSpans: [WordDiffSpan], newSpans: [WordDiffSpan]) {
        self.oldSpans = oldSpans
        self.newSpans = newSpans
    }
}

/// Computes a word-level (really: token-level) diff between two lines, meant to be called on the
/// two lines of a `.changed` `LineDiffEntry` so a UI can highlight just the differing spans.
///
/// Tokenization splits each line into maximal runs of "word" characters (letters, numbers, and
/// `_`, matching `Character.isLetter || Character.isNumber`) alternating with maximal runs of
/// everything else (whitespace and punctuation, kept as their own tokens so the span lists tile
/// the line exactly with no gaps). The token arrays are then diffed with the same
/// `CollectionDifference`-based approach as `diffLines(_:_:)`, just at token granularity instead
/// of line granularity — no separate diff algorithm is introduced.
///
/// This is a whole-line convenience: for two arbitrary lines (not already known to be a
/// `.changed` pair) it still produces a valid diff, but calling it on wildly different lines
/// (e.g. a `.removed` line against an unrelated `.inserted` line) will tend to highlight nearly
/// the entire line, which is expected — there's no shared structure for it to find.
///
/// - Complexity: `O(n log n)` in the number of tokens, inherited from `CollectionDifference`.
public func diffWords(_ oldLine: String, _ newLine: String) -> WordDiffResult {
    let oldTokens = tokenize(oldLine)
    let newTokens = tokenize(newLine)

    let difference = newTokens.difference(from: oldTokens)
    let removedOffsets = Set(difference.removals.map(\.offset))
    let insertedOffsets = Set(difference.insertions.map(\.offset))

    var oldSpans: [WordDiffSpan] = []
    var oldOffset = 0
    for (index, token) in oldTokens.enumerated() {
        let length = token.utf16.count
        let range = TextRange(lowerBound: oldOffset, upperBound: oldOffset + length)
        let kind: WordDiffKind = removedOffsets.contains(index) ? .removed : .unchanged
        oldSpans.append(WordDiffSpan(kind: kind, range: range, text: token))
        oldOffset += length
    }

    var newSpans: [WordDiffSpan] = []
    var newOffset = 0
    for (index, token) in newTokens.enumerated() {
        let length = token.utf16.count
        let range = TextRange(lowerBound: newOffset, upperBound: newOffset + length)
        let kind: WordDiffKind = insertedOffsets.contains(index) ? .inserted : .unchanged
        newSpans.append(WordDiffSpan(kind: kind, range: range, text: token))
        newOffset += length
    }

    return WordDiffResult(oldSpans: oldSpans, newSpans: newSpans)
}

/// Splits `line` into maximal runs of word characters alternating with maximal runs of
/// non-word characters, covering the whole string with no gaps or overlaps.
func tokenize(_ line: String) -> [Substring] {
    guard !line.isEmpty else { return [] }
    var tokens: [Substring] = []
    var start = line.startIndex
    var isWord = isWordCharacter(line[start])
    var index = line.index(after: start)
    while index < line.endIndex {
        let currentIsWord = isWordCharacter(line[index])
        if currentIsWord != isWord {
            tokens.append(line[start..<index])
            start = index
            isWord = currentIsWord
        }
        index = line.index(after: index)
    }
    tokens.append(line[start..<line.endIndex])
    return tokens
}

private func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
}
