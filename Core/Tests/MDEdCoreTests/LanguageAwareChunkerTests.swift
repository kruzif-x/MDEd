import Foundation
import Testing
@testable import MDEdCore

@Suite("LanguageAwareChunker")
struct LanguageAwareChunkerTests {

    // MARK: - The heading-detected-as-French case, explicitly

    /// Pins the exact false positive this type exists to avoid: run the real
    /// `NLLanguageRecognizer` on the raw text of a heading like `"## Installation"` and it can come
    /// back confidently misread as French (measured directly during this feature's own spike). A
    /// detector rigged to reproduce that misreading — "fr" whenever it's handed text containing
    /// "Installation" — stands in for it here; if `segments(of:)` ever produced a boundary at the
    /// heading, it could only be because the heading's own text reached the detector; that would be
    /// the bug. Both English prose paragraphs, before and after the heading, use lowercase
    /// "installation" mid-sentence deliberately, so the rig only ever fires on the heading itself.
    @Test func headingTextIsNeverHandedToTheLanguageDetectorEvenOneRiggedToMisdetectIt() {
        let text = """
        # Guide

        This paragraph explains the tool before installation begins, entirely in English prose.

        ## Installation

        This paragraph explains installation steps in the same plain English prose throughout.
        """
        func riggedDetector(_ block: String) -> String? {
            block.contains("Installation") ? "fr" : "en"
        }
        let segments = LanguageAwareChunker.segments(of: text, languageDetector: riggedDetector)
        #expect(segments.count == 1)
        #expect(segments[0].language == "en")
    }

    /// Same case, but with the real on-device detector rather than a rig — confirms the structural
    /// skip holds against the actual `NLLanguageRecognizer` behavior the spike measured, not just a
    /// synthetic stand-in for it.
    @Test func realDetectorDoesNotSplitAtAHeadingBetweenSameLanguageProse() {
        let text = """
        # Guide

        This paragraph explains what the tool does before you install it, in plain English prose.

        ## Installation

        This paragraph explains how to install the tool, again in plain English prose throughout.
        """
        let segments = LanguageAwareChunker.segments(of: text)
        #expect(segments.count == 1)
        #expect(segments[0].language == "en")
    }

    // MARK: - Structural blocks are never passed to the detector at all

    @Test func codeBlocksAndTablesAreNeverPassedToTheLanguageDetector() {
        let text = """
        # Doc

        An English paragraph long enough to be classified with confidence by the detector itself.

        ```swift
        let x = 1
        ```

        | Feature | Support |
        | --- | --- |
        | Foo | Yes |

        Another English paragraph, also long enough to register confidently as English prose text.
        """
        var sawStructuralText = false
        func detector(_ block: String) -> String? {
            if block.contains("let x = 1") || block.contains("Feature") {
                sawStructuralText = true
            }
            return block.hasPrefix("An English") || block.hasPrefix("Another English") ? "en" : nil
        }
        let segments = LanguageAwareChunker.segments(of: text, languageDetector: detector)
        #expect(!sawStructuralText)
        #expect(segments.count == 1)
        #expect(segments[0].language == "en")
    }

    // MARK: - Unclassified blocks inherit rather than split

    @Test func shortProseBelowTheMinimumLengthInheritsThePreviousLanguage() {
        let text = """
        This is a full English paragraph long enough to be classified confidently as English.

        Ok.

        This is another full English paragraph, also long enough to be classified confidently.
        """
        let segments = LanguageAwareChunker.segments(of: text)
        #expect(segments.count == 1)
        #expect(segments[0].language == "en")
    }

    @Test func lowConfidenceProseIsTreatedAsUnclassifiedAndInherits() {
        let text = "First block of real content.\n\nSecond block of real content."
        func flakyDetector(_ block: String) -> String? {
            // Simulates a low-confidence reading that should be discarded, not trusted.
            block.contains("First") ? "en" : nil
        }
        let segments = LanguageAwareChunker.segments(of: text, languageDetector: flakyDetector)
        #expect(segments.count == 1)
        #expect(segments[0].language == "en")
    }

    // MARK: - Genuine language changes do split, using the real detector

    @Test func realDetectorSplitsAtAGenuineLanguageChange() {
        let text = """
        # Welcome

        This is a fairly long paragraph written entirely in English, explaining what this \
        project does and why someone might want to use it in their own work.

        # Bem-vindo

        Este é um parágrafo bastante longo escrito inteiramente em português, explicando o que \
        este projeto faz e por que alguém poderia querer usá-lo no seu próprio trabalho.
        """
        let segments = LanguageAwareChunker.segments(of: text)
        #expect(segments.count == 2)
        #expect(segments[0].language == "en")
        #expect(segments[1].language == "pt")
    }

    // MARK: - No prose at all

    @Test func documentWithNoProseAtAllIsOneUnclassifiedSegment() {
        let text = "```\ncode only, no prose anywhere in this document\n```"
        let segments = LanguageAwareChunker.segments(of: text)
        #expect(segments.count == 1)
        #expect(segments[0].language == nil)
    }

    @Test func emptyDocumentProducesNoSegments() {
        #expect(LanguageAwareChunker.segments(of: "").isEmpty)
    }

    // MARK: - chunk(_:) end to end

    @Test func chunkRangesMapBackToTheOriginalDocumentAcrossSegments() {
        let english = (0..<50).map { "englishword\($0)" }.joined(separator: " ")
        let text = "# En\n\n\(english)\n\n# Pt\n\nEste texto em português explica algo com bastante " +
            "detalhe para o leitor entender melhor o assunto todo aqui apresentado agora mesmo."
        let chunks = LanguageAwareChunker.chunk(text, budgetTokens: 40, estimator: { $0.split(separator: " ").count })
        let ns = text as NSString
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            #expect(ns.substring(with: chunk.range.nsRange) == chunk.text)
        }
    }

    @Test func neverPacksTwoLanguagesIntoOneChunkEvenWhenBothWouldFitTheBudget() {
        let text = """
        # A

        This short English paragraph is long enough to be classified confidently as English text.

        # B

        Este parágrafo curto em português é longo o bastante para ser classificado com confiança \
        nesse idioma pelo reconhecedor usado aqui mesmo.
        """
        // Budget generous enough that, without language awareness, both sections would have
        // packed into a single chunk.
        let chunks = LanguageAwareChunker.chunk(text, budgetTokens: TokenEstimator.defaultChunkBudget)
        #expect(chunks.count >= 2)
        for chunk in chunks {
            let hasEnglishMarker = chunk.text.contains("English paragraph")
            let hasPortugueseMarker = chunk.text.contains("português")
            #expect(!(hasEnglishMarker && hasPortugueseMarker))
        }
    }

    @Test func singleLanguageDocumentChunksExactlyLikePlainDocumentChunker() {
        let text = "# Title\n\n" + (0..<300).map { "word\($0)" }.joined(separator: " ")
        let estimator: (String) -> Int = { $0.split(separator: " ").count }
        let plain = DocumentChunker.chunk(text, budgetTokens: 50, estimator: estimator)
        let languageAware = LanguageAwareChunker.chunk(text, budgetTokens: 50, estimator: estimator)
        #expect(languageAware.map(\.text) == plain.map(\.text))
    }
}
