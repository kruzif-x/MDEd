import Testing
@testable import MDEdCore

@Suite("TokenEstimator")
struct TokenEstimatorTests {

    @Test func emptyStringIsZeroTokens() {
        #expect(TokenEstimator.estimate("") == 0)
    }

    @Test func nonEmptyTextIsAlwaysAtLeastOneToken() {
        #expect(TokenEstimator.estimate("a") > 0)
        #expect(TokenEstimator.estimate(" ") == 0) // pure whitespace: no words, no CJK characters
    }

    @Test func longerTextNeverEstimatesFewerTokens() {
        let short = "The quick brown fox."
        let longer = short + " " + short + " " + short
        #expect(TokenEstimator.estimate(longer) > TokenEstimator.estimate(short))
    }

    /// Pinned against the spike's one real measurement: a 2,500-word document was reported by
    /// `GenerationError.exceededContextWindowSize` as 4,566 tokens. The estimator is deliberately
    /// calibrated to overestimate a little (see `TokenEstimator`'s doc comment), so it should land
    /// at or above that figure, not wildly above it.
    @Test func calibratedAgainstSpikeMeasurement() {
        let words = Array(repeating: "word", count: 2500).joined(separator: " ")
        let estimate = TokenEstimator.estimate(words)
        #expect(estimate >= 4566)
        #expect(estimate <= 4566 + 500) // overestimate, but not by an unreasonable margin
    }

    @Test func fitsUnderContextWindowAt1500Words() {
        // The spike's own practical-input-budget figure: 1,500 words fit comfortably.
        let words = Array(repeating: "word", count: 1500).joined(separator: " ")
        #expect(TokenEstimator.estimate(words) < TokenEstimator.contextWindowLimit)
    }

    @Test func cjkCostsMorePerCharacterThanLatinProse() {
        // Same *character* count (not word count): a subword tokenizer compresses whitespace-
        // delimited Latin words (several characters sharing one token) far better than CJK script,
        // where each character tends to cost close to its own token — so for equal character
        // counts, CJK should estimate meaningfully higher.
        let latin = "the quick brown fox jumps over the lazy dog again and"
        let cjk = String(repeating: "你", count: latin.count)
        #expect(cjk.count == latin.count)
        #expect(TokenEstimator.estimate(cjk) > TokenEstimator.estimate(latin))
    }

    @Test func mixedCJKAndLatinSumsBothContributions() {
        let latinOnly = TokenEstimator.estimate("hello world")
        let cjkOnly = TokenEstimator.estimate("你好世界")
        let mixed = TokenEstimator.estimate("hello world 你好世界")
        // Each call rounds up independently, so an exact sum isn't guaranteed — but the combined
        // estimate should be within a rounding unit of the two contributions added together.
        #expect(abs(mixed - (latinOnly + cjkOnly)) <= 1)
    }

    @Test func defaultChunkBudgetLeavesHeadroomUnderContextWindow() {
        #expect(TokenEstimator.defaultChunkBudget < TokenEstimator.contextWindowLimit)
        // Headroom should be substantial — instructions + response share the window too.
        #expect(TokenEstimator.contextWindowLimit - TokenEstimator.defaultChunkBudget > 1000)
    }
}
