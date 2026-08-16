import MDEdCore

/// A human-readable rendering of `MarkupComparator`'s syntax kinds, shared by `AICommandRunner`
/// (the corrective retry instruction) and `AIReviewView` (the on-screen warning) so both describe
/// the same delta the same way rather than drifting apart as two separate, hand-maintained copies.
enum MarkupKindDescription {
    static func describe(_ kinds: [SyntaxKind]) -> String {
        kinds.map { kind in
            switch kind {
            case .heading: return "headings"
            case .emphasis: return "italic emphasis"
            case .strong: return "bold"
            case .strikethrough: return "strikethrough"
            case .inlineCode: return "inline code"
            case .codeBlock: return "code blocks"
            case .diagramBlock: return "diagram blocks"
            case .inlineMath: return "inline math"
            case .displayMath: return "display math"
            case .link: return "links"
            case .image: return "images"
            case .listItem: return "list items"
            case .blockQuote: return "block quotes"
            case .thematicBreak: return "thematic breaks"
            case .table: return "tables"
            }
        }.joined(separator: ", ")
    }
}
