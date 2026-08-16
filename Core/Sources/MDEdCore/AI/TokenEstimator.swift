/// Token-count estimation for FoundationModels input, calibrated against real measurements taken
/// against the on-device model (not re-derived here — see the Stage 4 spike this project was built
/// from): a 1,500-word document fit comfortably; a 2,500-word document failed with
/// `GenerationError.exceededContextWindowSize`, whose message reported "Content contains 4566
/// tokens, which exceeds the maximum allowed context size of 4096" — the one hard token-count data
/// point available, giving ≈1.83 tokens per word for ordinary prose.
///
/// FoundationModels exposes no public tokenizer, so this is necessarily an estimate, not an exact
/// count. It's built to *overestimate* rather than underestimate: an overestimate costs the
/// chunker one extra, smaller-than-strictly-necessary chunk; an underestimate sends a chunk the
/// model rejects outright with a `GenerationError` this app then has to explain to the user
/// instead of simply not producing.
public enum TokenEstimator {

    /// The hard per-session context ceiling FoundationModels enforces, measured directly (see this
    /// type's doc comment). Exposed mainly for tests/diagnostics — everyday budgeting should go
    /// through `defaultChunkBudget`, which already reserves headroom below this.
    public static let contextWindowLimit = 4096

    /// The token budget a single chunk's *input* should stay under. `contextWindowLimit` is shared
    /// by the input, the instructions prompt, and the model's own response, so this reserves
    /// roughly a third of the window for those — landing close to the spike's own characterization
    /// of the practical budget as "roughly 1,500 words, less once instructions and response share
    /// the window" (2,600 tokens ÷ ~1.9 tokens/word ≈ 1,370 words).
    public static let defaultChunkBudget = 2600

    /// Tokens per whitespace-delimited "word" of non-CJK text, calibrated from the spike's 2,500
    /// word → 4,566 token data point (4566 / 2500 ≈ 1.83), rounded up to bias this estimator toward
    /// overestimating rather than underestimating — see this type's doc comment for why that's the
    /// safe direction.
    private static let latinTokensPerWord = 1.9

    /// Tokens per CJK character (Han, Hiragana, Katakana, Hangul). Subword tokenizers compress
    /// whitespace-delimited Latin words far better than CJK script, where each character usually
    /// costs close to its own token rather than sharing one with its neighbors the way common
    /// English syllables do. The spike didn't exercise CJK input (it translated *into* CJK-adjacent
    /// scripts and summarized a Portuguese document, neither of which measures this), so — unlike
    /// `latinTokensPerWord` — this is a documented, deliberately conservative estimate rather than
    /// a calibrated one; `TokenEstimatorTests` pins the behavior this constant produces so a future
    /// recalibration is a one-line, test-visible change.
    private static let cjkTokensPerCharacter = 1.6

    /// Estimates the token count `text` would consume as model input.
    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var latinWordCount = 0
        var cjkCharacterCount = 0
        var inWord = false

        for character in text {
            if isCJKCharacter(character) {
                cjkCharacterCount += 1
                inWord = false
                continue
            }
            if character.isWhitespace || character.isNewline {
                inWord = false
                continue
            }
            if !inWord {
                latinWordCount += 1
                inWord = true
            }
        }

        let tokens = Double(latinWordCount) * latinTokensPerWord + Double(cjkCharacterCount) * cjkTokensPerCharacter
        return Int(tokens.rounded(.up))
    }
}

// MARK: - CJK detection

/// Mirrors `WordCount`'s own CJK scalar ranges (Han incl. Extensions A/B, Hiragana, Katakana,
/// Hangul Syllables). Kept as this file's own small copy rather than reaching into `WordCount`'s
/// file-private helpers of the same shape — six lines of Unicode ranges duplicated is cheaper than
/// widening `WordCount`'s public API for a caller in an unrelated feature area.
private func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x4E00...0x9FFF,   // CJK Unified Ideographs
         0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
         0x20000...0x2A6DF, // CJK Unified Ideographs Extension B
         0x3040...0x309F,   // Hiragana
         0x30A0...0x30FF,   // Katakana
         0xAC00...0xD7AF:   // Hangul Syllables
        return true
    default:
        return false
    }
}

private func isCJKCharacter(_ character: Character) -> Bool {
    !character.unicodeScalars.isEmpty && character.unicodeScalars.allSatisfy(isCJKScalar)
}
