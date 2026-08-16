import SwiftUI
import MDEdCore

/// The user-facing face of `NoteAnchorResolution`'s four states — one vocabulary shared by the
/// gutter dots, the text-column bars, and the notes popovers, so a note reads the same way
/// wherever the user meets it.
enum NoteStatusKind {
    /// The passage plus its recorded context still match uniquely — see `ReviewNote`.
    case exact
    /// The passage survives uniquely but its recorded surroundings don't.
    case relocated
    /// The passage now occurs more than once; which one the note belongs to is unknowable.
    case ambiguous
    /// The passage is gone.
    case unmatched

    init(_ resolution: NoteAnchorResolution) {
        switch resolution {
        case .exact: self = .exact
        case .relocated: self = .relocated
        case .ambiguous: self = .ambiguous
        case .unmatched: self = .unmatched
        }
    }

    /// Deliberately not the resolver's raw vocabulary ("exact"/"relocated"): these strings are
    /// what a reader sees, and each names what the *note* is, not what the algorithm did.
    var label: String {
        switch self {
        case .exact: "Anchored"
        case .relocated: "Moved"
        case .ambiguous: "Ambiguous"
        case .unmatched: "Unmatched"
        }
    }

    var color: Color {
        switch self {
        case .exact: .yellow
        case .relocated: .orange
        case .ambiguous: .purple
        case .unmatched: .red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .exact: .systemYellow
        case .relocated: .systemOrange
        case .ambiguous: .systemPurple
        case .unmatched: .systemRed
        }
    }

    var symbolName: String {
        switch self {
        case .exact: "checkmark.circle.fill"
        case .relocated: "arrow.triangle.2.circlepath"
        case .ambiguous: "questionmark.circle"
        case .unmatched: "xmark.circle"
        }
    }
}

/// One note's marker as the line-number gutter draws and hit-tests it — the App-facing payload
/// `ReviewNotesController.gutterMarkers(in:)` produces, kept free of any AppKit geometry so
/// the controller stays testable-by-reading.
struct NoteMarker {
    let noteID: UUID
    let kind: NoteStatusKind
}

/// One row of the "Show All Notes" list.
struct NotesListRow: Identifiable {
    let id: UUID
    let kind: NoteStatusKind
    /// `"Ln 12"` for notes with a resolvable location; `nil` for unmatched ones.
    let lineLabel: String?
    let noteText: String
    let excerpt: String
}

// MARK: - Popover content
//
// All three views are deliberately plain SwiftUI-in-a-popover (the same pairing the AI review
// sheet already uses). Buttons carry `.defaultAction`/`.cancelAction` shortcuts so Return and
// Escape work the way every AppKit popover user expects.

/// The "Add Note to Selection" (or edit-existing) composer.
struct NoteEditorView: View {
    let excerpt: String
    let saveLabel: String
    let initialText: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(excerpt: String, saveLabel: String = "Add Note", initialText: String = "", onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.excerpt = excerpt
        self.saveLabel = saveLabel
        self.initialText = initialText
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(excerpt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 88)
                .focused($focused)
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(saveLabel) { onSave(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { focused = true }
    }
}

/// A single note, as the gutter dot's popover shows it.
struct NoteDetailView: View {
    let row: NotesListRow
    let onReveal: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: row.kind.symbolName)
                    .foregroundStyle(row.kind.color)
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(row.noteText)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.excerpt)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
            HStack {
                Button("Delete", role: .destructive, action: onDelete)
                Spacer()
                Button("Edit…", action: onEdit)
                Button("Reveal", action: onReveal)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var subtitle: String {
        row.lineLabel.map { "\($0) · \(row.kind.label)" } ?? row.kind.label
    }
}

/// Every note on the document, one row per note — the one surface where unmatched notes are
/// still reachable (they have no location, so neither the gutter nor a text bar can show them).
struct NotesListView: View {
    let rows: [NotesListRow]
    let onSelect: (UUID) -> Void
    let onEdit: (UUID) -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("No notes yet. Select some text and choose Notes ▸ Add Note to Selection (⌥⌘N).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { row in
                            NotesListRowView(row: row) { onSelect(row.id) } edit: { onEdit(row.id) } delete: { onDelete(row.id) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
                Text("\(rows.count) note\(rows.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: 330)
    }
}

private struct NotesListRowView: View {
    let row: NotesListRow
    let select: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(row.kind.color)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.noteText)
                    .font(.callout)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Edit this note")
            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete this note")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(subtitle): \(row.noteText)")
    }

    private var subtitle: String {
        row.lineLabel.map { "\($0) · \(row.kind.label)" } ?? row.kind.label
    }
}
