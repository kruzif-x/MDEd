import Testing
import Foundation
@testable import MDEdCore

@Suite("SyntaxMap")
struct SyntaxMapTests {

    /// Slices `source` at `range` using `NSString`, exactly mirroring how an `NSTextStorage`-backed
    /// text view would read the range back — the closest thing to an end-to-end check that
    /// `TextRange`'s UTF-16 offsets are correct, independent of any assumption about how they were
    /// computed.
    private func slice(_ source: String, _ range: MDEdCore.TextRange) -> String {
        (source as NSString).substring(with: range.nsRange)
    }

    // MARK: Heading

    @Test func headingMarkerVersusContent() throws {
        let source = "## Hello World"
        let elements = syntaxMap(of: source)
        let heading = elements.first { if case .heading = $0.kind { return true }; return false }
        let h = try #require(heading)
        guard case .heading(let level) = h.kind else { Issue.record("not a heading"); return }
        #expect(level == 2)
        #expect(h.markerRanges.count == 1)
        #expect(slice(source, h.markerRanges[0]) == "## ")
        let content = try #require(h.contentRange)
        #expect(slice(source, content) == "Hello World")
    }

    @Test func headingLevelsOneThroughSix() throws {
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            let source = "\(hashes) Title"
            let elements = syntaxMap(of: source)
            let heading = elements.first { if case .heading = $0.kind { return true }; return false }
            let h = try #require(heading)
            guard case .heading(let parsedLevel) = h.kind else { Issue.record("not a heading"); return }
            #expect(parsedLevel == level)
            #expect(slice(source, h.markerRanges[0]) == "\(hashes) ")
        }
    }

    // MARK: Emphasis / Strong / Strikethrough

    @Test func strongMarkerVersusContent() throws {
        let source = "This is **bold** text."
        let elements = syntaxMap(of: source)
        let strong = try #require(elements.first { $0.kind == .strong })
        #expect(strong.markerRanges.count == 2)
        #expect(slice(source, strong.markerRanges[0]) == "**")
        #expect(slice(source, strong.markerRanges[1]) == "**")
        let content = try #require(strong.contentRange)
        #expect(slice(source, content) == "bold")
    }

    @Test func emphasisWithUnderscoreDelimiters() throws {
        let source = "This is _italic_ text."
        let elements = syntaxMap(of: source)
        let emphasis = try #require(elements.first { $0.kind == .emphasis })
        #expect(slice(source, emphasis.markerRanges[0]) == "_")
        #expect(slice(source, emphasis.markerRanges[1]) == "_")
        #expect(slice(source, try #require(emphasis.contentRange)) == "italic")
    }

    @Test func nestedEmphasisInsideStrong() throws {
        let source = "**bold *and italic* text**"
        let elements = syntaxMap(of: source)
        #expect(elements.contains { $0.kind == .strong })
        #expect(elements.contains { $0.kind == .emphasis })
        let emphasis = try #require(elements.first { $0.kind == .emphasis })
        #expect(slice(source, try #require(emphasis.contentRange)) == "and italic")
    }

    @Test func strikethroughMarkerVersusContent() throws {
        let source = "This is ~~deleted~~ text."
        let elements = syntaxMap(of: source)
        let strike = try #require(elements.first { $0.kind == .strikethrough })
        #expect(slice(source, strike.markerRanges[0]) == "~~")
        #expect(slice(source, strike.markerRanges[1]) == "~~")
        #expect(slice(source, try #require(strike.contentRange)) == "deleted")
    }

    // MARK: Inline code

    @Test func inlineCodeMarkerVersusContent() throws {
        let source = "Run `let x = 1` now."
        let elements = syntaxMap(of: source)
        let code = try #require(elements.first { $0.kind == .inlineCode })
        #expect(slice(source, code.markerRanges[0]) == "`")
        #expect(slice(source, code.markerRanges[1]) == "`")
        #expect(slice(source, try #require(code.contentRange)) == "let x = 1")
    }

    @Test func inlineCodeWithDoubleBacktickFence() throws {
        let source = "Value: ``a`b``."
        let elements = syntaxMap(of: source)
        let code = try #require(elements.first { $0.kind == .inlineCode })
        #expect(slice(source, code.markerRanges[0]) == "``")
        #expect(slice(source, code.markerRanges[1]) == "``")
    }

    // MARK: Code block / diagram block

    @Test func fencedCodeBlockLanguageAndMarkers() throws {
        let source = "```swift\nlet x = 1\n```"
        let elements = syntaxMap(of: source)
        let block = try #require(elements.first { if case .codeBlock = $0.kind { return true }; return false })
        guard case .codeBlock(let language) = block.kind else { Issue.record("wrong kind"); return }
        #expect(language == "swift")
        #expect(block.markerRanges.count == 2)
        #expect(slice(source, block.markerRanges[0]) == "```swift\n")
        #expect(slice(source, block.markerRanges[1]) == "```")
        #expect(slice(source, try #require(block.contentRange)) == "let x = 1\n")
    }

    @Test func mermaidFenceReportedAsDiagramBlock() throws {
        let source = "```mermaid\ngraph TD;\nA-->B;\n```"
        let elements = syntaxMap(of: source)
        #expect(elements.contains { $0.kind == .diagramBlock })
        #expect(!elements.contains { if case .codeBlock = $0.kind { return true }; return false })
    }

    @Test func codeBlockWithNoLanguage() throws {
        let source = "```\nplain\n```"
        let elements = syntaxMap(of: source)
        let block = try #require(elements.first { if case .codeBlock = $0.kind { return true }; return false })
        guard case .codeBlock(let language) = block.kind else { Issue.record("wrong kind"); return }
        #expect(language == nil)
    }

    // MARK: Links and images

    @Test func linkMarkerVersusContentAndDestination() throws {
        let source = "See [the docs](https://example.com/page) for more."
        let elements = syntaxMap(of: source)
        let link = try #require(elements.first { if case .link = $0.kind { return true }; return false })
        guard case .link(let destination) = link.kind else { Issue.record("wrong kind"); return }
        #expect(destination == "https://example.com/page")
        #expect(slice(source, try #require(link.contentRange)) == "the docs")
        #expect(slice(source, link.markerRanges[0]) == "[")
        #expect(slice(source, link.markerRanges[1]) == "](https://example.com/page)")
    }

    @Test func imageMarkerVersusContentAndDestination() throws {
        let source = "![a cat](cat.png)"
        let elements = syntaxMap(of: source)
        let image = try #require(elements.first { if case .image = $0.kind { return true }; return false })
        guard case .image(let destination) = image.kind else { Issue.record("wrong kind"); return }
        #expect(destination == "cat.png")
        #expect(slice(source, try #require(image.contentRange)) == "a cat")
        #expect(slice(source, image.markerRanges[0]) == "![")
    }

    // MARK: List items

    @Test func unorderedListItemMarker() throws {
        let source = "- First item\n- Second item"
        let elements = syntaxMap(of: source)
        let items = elements.filter { $0.kind == .listItem }
        #expect(items.count == 2)
        #expect(slice(source, items[0].markerRanges[0]) == "- ")
        #expect(slice(source, try #require(items[0].contentRange)) == "First item")
    }

    @Test func orderedListItemMarker() throws {
        let source = "1. First\n2. Second"
        let elements = syntaxMap(of: source)
        let items = elements.filter { $0.kind == .listItem }
        #expect(items.count == 2)
        #expect(slice(source, items[0].markerRanges[0]) == "1. ")
        #expect(slice(source, items[1].markerRanges[0]) == "2. ")
    }

    @Test func taskListCheckboxIsPartOfMarker() throws {
        let source = "- [x] Done thing"
        let elements = syntaxMap(of: source)
        let item = try #require(elements.first { $0.kind == .listItem })
        #expect(slice(source, item.markerRanges[0]) == "- [x] ")
        #expect(slice(source, try #require(item.contentRange)) == "Done thing")
    }

    // MARK: Block quote (multi-line marker)

    @Test func blockQuoteMarkerPerLine() throws {
        let source = "> Line one\n> Line two"
        let elements = syntaxMap(of: source)
        let quote = try #require(elements.first { $0.kind == .blockQuote })
        #expect(quote.markerRanges.count == 2)
        #expect(slice(source, quote.markerRanges[0]) == "> ")
        #expect(slice(source, quote.markerRanges[1]) == "> ")
    }

    // MARK: Thematic break

    @Test func thematicBreakHasNoContent() throws {
        let source = "above\n\n---\n\nbelow"
        let elements = syntaxMap(of: source)
        let brk = try #require(elements.first { $0.kind == .thematicBreak })
        #expect(brk.contentRange == nil)
        // swift-markdown's own `range` for a thematic break includes its trailing line
        // terminator; since the whole element is marker with no content, that terminator is
        // simply part of the (single) marker range too.
        #expect(slice(source, brk.markerRanges[0]) == "---\n")
    }

    // MARK: Table

    @Test func tableIsDetected() throws {
        let source = "| a | b |\n| - | - |\n| 1 | 2 |\n"
        let elements = syntaxMap(of: source)
        #expect(elements.contains { $0.kind == .table })
    }

    // MARK: Math / diagram (not part of CommonMark)

    @Test func inlineMathDetected() throws {
        let source = "The value $x^2 + 1$ is positive."
        let elements = syntaxMap(of: source)
        let math = try #require(elements.first { $0.kind == .inlineMath })
        #expect(slice(source, try #require(math.contentRange)) == "x^2 + 1")
        #expect(slice(source, math.markerRanges[0]) == "$")
        #expect(slice(source, math.markerRanges[1]) == "$")
    }

    @Test func displayMathDetected() throws {
        let source = "Consider:\n\n$$\nE = mc^2\n$$\n\nDone."
        let elements = syntaxMap(of: source)
        let math = try #require(elements.first { $0.kind == .displayMath })
        #expect(slice(source, math.markerRanges[0]) == "$$")
        #expect(slice(source, math.markerRanges[1]) == "$$")
    }

    @Test func dollarSignsAsCurrencyAreNotMistakenForMath() throws {
        let source = "Prices range from $5 to $10 depending on size."
        let elements = syntaxMap(of: source)
        #expect(!elements.contains { $0.kind == .inlineMath })
    }

    @Test func dollarInsideInlineCodeIsNotTreatedAsMath() throws {
        let source = "Use the `$PATH` variable."
        let elements = syntaxMap(of: source)
        #expect(!elements.contains { $0.kind == .inlineMath })
    }

    // MARK: Non-ASCII offset correctness — the critical part

    @Test func emojiBeforeHeadingContentDoesNotShiftOffsets() throws {
        let source = "## 🎉 Party Time"
        let elements = syntaxMap(of: source)
        let heading = try #require(elements.first { if case .heading = $0.kind { return true }; return false })
        #expect(slice(source, heading.markerRanges[0]) == "## ")
        #expect(slice(source, try #require(heading.contentRange)) == "🎉 Party Time")
    }

    @Test func emojiInsideStrongContent() throws {
        let source = "Great job **🎉🎉🎉** team!"
        let elements = syntaxMap(of: source)
        let strong = try #require(elements.first { $0.kind == .strong })
        #expect(slice(source, try #require(strong.contentRange)) == "🎉🎉🎉")
        #expect(slice(source, strong.markerRanges[1]) == "**")
    }

    @Test func cjkHeadingContent() throws {
        let source = "# 你好世界"
        let elements = syntaxMap(of: source)
        let heading = try #require(elements.first { if case .heading = $0.kind { return true }; return false })
        #expect(slice(source, heading.markerRanges[0]) == "# ")
        #expect(slice(source, try #require(heading.contentRange)) == "你好世界")
    }

    @Test func cjkBeforeAndInsideEmphasis() throws {
        let source = "中文 *强调文字* 后面"
        let elements = syntaxMap(of: source)
        let emphasis = try #require(elements.first { $0.kind == .emphasis })
        #expect(slice(source, try #require(emphasis.contentRange)) == "强调文字")
    }

    @Test func combiningCharacterDoesNotShiftSubsequentRanges() throws {
        // "é" here is "e" + U+0301 COMBINING ACUTE ACCENT — two Unicode scalars, one grapheme
        // cluster, two UTF-16 code units. A byte-vs-UTF16 mixup would shift everything after it.
        let combiningE = "e\u{0301}"
        let source = "Café **\(combiningE)xtra bold** words"
        let elements = syntaxMap(of: source)
        let strong = try #require(elements.first { $0.kind == .strong })
        #expect(slice(source, try #require(strong.contentRange)) == "\(combiningE)xtra bold")
    }

    @Test func multipleNonASCIILinesKeepHeadingsAligned() throws {
        let source = """
        # 😀 First
        Some 中文 prose here.
        ## Sécônd Héading
        More **bôld🎉** text.
        """
        let elements = syntaxMap(of: source)
        let headings = elements.compactMap { element -> (Int, MDEdCore.TextRange)? in
            guard case .heading(let level) = element.kind else { return nil }
            return (level, element.contentRange!)
        }
        #expect(headings.count == 2)
        #expect(slice(source, headings[0].1) == "😀 First")
        #expect(slice(source, headings[1].1) == "Sécônd Héading")
        let strong = try #require(elements.first { $0.kind == .strong })
        #expect(slice(source, try #require(strong.contentRange)) == "bôld🎉")
    }

    // MARK: CRLF line endings

    @Test func crlfLineEndingsKeepOffsetsAligned() throws {
        // LineOffsetTable does its own manual scalar-by-scalar \r\n detection (independent of the
        // Diff module's line-array based CRLF handling) — exercise it directly with a heading and
        // a strong span after CRLF-terminated lines, to prove line/column accounting isn't thrown
        // off by the two-code-unit terminator.
        let source = "First line\r\n## Heading After CRLF\r\nThird **bold** line\r\n"
        let elements = syntaxMap(of: source)
        let heading = try #require(elements.first { if case .heading = $0.kind { return true }; return false })
        #expect(slice(source, heading.markerRanges[0]) == "## ")
        #expect(slice(source, try #require(heading.contentRange)) == "Heading After CRLF")
        let strong = try #require(elements.first { $0.kind == .strong })
        #expect(slice(source, try #require(strong.contentRange)) == "bold")
    }

    @Test func crMixedWithLFLineEndings() throws {
        // Lone \r (old classic Mac style) terminators, mixed with a trailing \n-only line.
        let source = "one\rtwo\r# Heading\nthree"
        let elements = syntaxMap(of: source)
        let heading = try #require(elements.first { if case .heading = $0.kind { return true }; return false })
        #expect(slice(source, try #require(heading.contentRange)) == "Heading")
    }

    // MARK: Ranges tile / are consistent

    @Test func markerAndContentRangesUnionToFullRange() throws {
        let source = "## **Bold Heading**\n\nSome `code` and [a link](url) and *emphasis*."
        let elements = syntaxMap(of: source)
        for element in elements {
            var covered = element.markerRanges
            if let content = element.contentRange {
                covered.append(content)
            }
            guard !covered.isEmpty else { continue }
            let minLower = covered.map(\.lowerBound).min()!
            let maxUpper = covered.map(\.upperBound).max()!
            #expect(minLower == element.range.lowerBound)
            #expect(maxUpper == element.range.upperBound)
        }
    }

    // MARK: Depth

    @Test func depthReflectsNesting() throws {
        let source = "> **bold in quote**"
        let elements = syntaxMap(of: source)
        let quote = try #require(elements.first { $0.kind == .blockQuote })
        let strong = try #require(elements.first { $0.kind == .strong })
        #expect(strong.depth > quote.depth)
    }
}
