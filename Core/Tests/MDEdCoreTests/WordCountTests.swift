import Testing
@testable import MDEdCore

@Suite("WordCount")
struct WordCountTests {

    // MARK: stripMarkdown

    @Test func stripsHeadingMarker() {
        #expect(WordCount.stripMarkdown("# Hello World") == "Hello World")
    }

    @Test func stripsBoldMarkers() {
        #expect(WordCount.stripMarkdown("**bold text**") == "bold text")
    }

    @Test func stripsItalicMarkers() {
        #expect(WordCount.stripMarkdown("*italic text*") == "italic text")
    }

    @Test func stripsUnderscoreEmphasisMarkers() {
        #expect(WordCount.stripMarkdown("_italic text_") == "italic text")
        #expect(WordCount.stripMarkdown("__bold text__") == "bold text")
    }

    @Test func stripsInlineCode() {
        #expect(WordCount.stripMarkdown("Use `print()` here") == "Use   here")
    }

    @Test func stripsFencedCodeBlock() {
        let md = "before\n```\ncode here\n```\nafter"
        #expect(WordCount.stripMarkdown(md) == "before\n \nafter")
    }

    @Test func stripsInlineLinkKeepingText() {
        #expect(WordCount.stripMarkdown("[click here](https://example.com)") == "click here")
    }

    @Test func stripsReferenceLinkKeepingText() {
        #expect(WordCount.stripMarkdown("[click here][1]") == "click here")
    }

    @Test func stripsImageEntirely() {
        #expect(WordCount.stripMarkdown("![alt text](image.png)") == " ")
    }

    @Test func stripsBlockQuoteMarker() {
        #expect(WordCount.stripMarkdown("> quoted line") == "quoted line")
    }

    @Test func stripsHTMLTags() {
        #expect(WordCount.stripMarkdown("<p>Some text</p>") == " Some text ")
    }

    @Test func stripsThematicBreak() {
        #expect(WordCount.stripMarkdown("---") == "")
    }

    @Test func stripsTablePipes() {
        #expect(WordCount.stripMarkdown("| col1 | col2 |") == "  col1   col2  ")
    }

    @Test func stripsUnorderedListMarker() {
        #expect(WordCount.stripMarkdown("- one\n- two") == "one\ntwo")
    }

    @Test func stripsOrderedListMarker() {
        #expect(WordCount.stripMarkdown("1. one\n2. two") == "one\ntwo")
    }

    // MARK: countWords

    @Test func emptyInputCountsZero() {
        #expect(WordCount.countWords("") == 0)
    }

    @Test func whitespaceOnlyCountsZero() {
        #expect(WordCount.countWords("   \n\t  ") == 0)
    }

    @Test func simpleSentence() {
        #expect(WordCount.countWords("Hello world") == 2)
    }

    @Test func multipleSpacesCollapse() {
        #expect(WordCount.countWords("one   two   three") == 3)
    }

    @Test func newlinesSeparateWords() {
        #expect(WordCount.countWords("one\ntwo\nthree") == 3)
    }

    @Test func unicodeLatinWordsCountAsOne() {
        #expect(WordCount.countWords("café résumé naïve") == 3)
    }

    @Test func cjkCharactersCountedIndividually() {
        #expect(WordCount.countWords("你好世界") == 4)
    }

    @Test func mixedCJKAndLatin() {
        #expect(WordCount.countWords("Hello 世界 world") == 4)
    }

    @Test func punctuationDoesNotCreateExtraWords() {
        #expect(WordCount.countWords("Hello, world!") == 2)
    }

    @Test func japaneseHiraganaAndKatakanaCountedIndividually() {
        // 4 hiragana (ひらがな) + 4 katakana (カタカナ) = 8 individual "words".
        #expect(WordCount.countWords("ひらがなカタカナ") == 8)
    }

    @Test func koreanHangulCountedIndividually() {
        #expect(WordCount.countWords("안녕하세요") == 5)
    }

    // MARK: readingTime

    @Test func zeroWordsReadingTime() {
        #expect(WordCount.readingTime(forWordCount: 0) == "< 1 min read")
    }

    @Test func fewerThanWPMReadingTime() {
        #expect(WordCount.readingTime(forWordCount: 100) == "< 1 min read")
    }

    @Test func exactlyOneMinuteReadingTime() {
        #expect(WordCount.readingTime(forWordCount: 238) == "1 min read")
    }

    @Test func multipleMinutesReadingTime() {
        #expect(WordCount.readingTime(forWordCount: 238 * 5) == "5 min read")
    }

    @Test func roundingReadingTime() {
        // 357 / 238 = 1.5 -> banker's rounding rounds to the nearest even minute: 2.
        #expect(WordCount.readingTime(forWordCount: 357) == "2 min read")
    }

    // MARK: analyze (full pipeline)

    @Test func analyzeStripsThenCounts() {
        let result = WordCount.analyze("# Title\n\nSome **bold** prose with a [link](https://example.com).")
        // "Title", "Some", "bold", "prose", "with", "a", "link" = 7 words.
        #expect(result.wordCount == 7)
        #expect(result.readingTime == "< 1 min read")
    }

    @Test func analyzeOnEmptyInput() {
        let result = WordCount.analyze("")
        #expect(result.wordCount == 0)
        #expect(result.readingTime == "< 1 min read")
    }

    @Test func analyzeExcludesCodeBlockFromCount() {
        let withCode = WordCount.analyze("Intro text.\n\n```swift\nlet x = someReallyLongIdentifierName + anotherOne\n```\n\nOutro text.")
        let withoutCode = WordCount.analyze("Intro text.\n\nOutro text.")
        #expect(withCode.wordCount == withoutCode.wordCount)
    }

    @Test func analyzeCountsLinkTextNotURL() {
        let result = WordCount.analyze("Read [the documentation](https://example.com/very/long/path/that/would/inflate/count) now.")
        // "Read", "the", "documentation", "now" = 4 words — the URL must not be counted.
        #expect(result.wordCount == 4)
    }
}
