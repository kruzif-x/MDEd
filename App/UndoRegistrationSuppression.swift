import Foundation

/// Runs a programmatic, attribute-only `NSTextStorage` mutation without letting it register on
/// `undoManager`'s stack.
///
/// This exists because `NSTextView` (with `allowsUndo == true`, which every text view in this app
/// has) automatically registers an undo action for *any* edit that lands on its backing
/// `NSTextStorage` — including a plain `addAttribute`/`setAttributes` pass with no character
/// change, made directly against the storage rather than through the text view's own editing
/// methods. `NSDocument`'s change-count tracking, in turn, treats a closed undo group as "the
/// document changed" regardless of whether that group's action was a real edit or a re-run of
/// syntax highlighting. Left alone, that chain means every attribute-only pass — the initial
/// styling on open, a debounced restyle after a real edit, a settings change, live-preview marker
/// hiding, a comparison pane's diff decoration — quietly registers an undo step and marks the
/// document edited, even though nothing the user typed changed. Since `Document.autosavesInPlace`
/// is `true`, a document macOS believes has unsaved changes eventually gets written back to disk —
/// so this was silently rewriting files on nothing more than being opened.
///
/// `MarkdownStyler.restyle`'s own doc comment already states the intended invariant — restyling
/// "never disturbs the text view's undo stack or the caret position" — this function is what
/// actually enforces it. Every call site that applies attributes programmatically, without a
/// character being typed, should route through here.
///
/// Wrapping something that was never going to register undo in the first place (a `nil` undo
/// manager, or a body that turns out not to touch the storage) is always safe — this only ever
/// *suppresses* registration for the duration of `body`, restoring the previous state
/// unconditionally afterward.
func withoutRegisteringUndo(on undoManager: UndoManager?, _ body: () -> Void) {
    undoManager?.disableUndoRegistration()
    defer { undoManager?.enableUndoRegistration() }
    body()
}
