import AppKit

/// Owns one `NSTextLayoutManager`'s membership in an `NSTextContentStorage`'s shared set of
/// layout managers, and guarantees it gets detached again exactly once — via `deinit`, or
/// explicitly via `detach()` — no matter how many views end up sharing that content storage.
///
/// This exists to fix a real leak in the app: several views (an editor tab, a comparison pane —
/// see the app target's `Document` doc comment for why they deliberately share one
/// `NSTextContentStorage`) each attached their own `NSTextLayoutManager` via
/// `addTextLayoutManager(_:)`, but nothing ever called the matching `removeTextLayoutManager(_:)`
/// when that view's window closed. Every closed window left its layout manager — and the
/// `NSTextContainer`/`NSTextView` it retained — attached to the document's content storage for as
/// long as the document stayed open, both a memory leak and a source of stale layout managers
/// accumulating across repeated open/close cycles of the same document.
///
/// The fix is ownership, not a manual call site to remember: whoever asks for a layout manager
/// (the app target's `Document.makeTextContainer()`) gets back a `TextLayoutAttachment` alongside
/// the container, and is expected to hold it for exactly as long as it uses that container —
/// typically as a stored property on the owning view controller. When that view controller
/// deallocates, this attachment deallocates with it, and `deinit` does the detach automatically.
/// No view controller needs its own `deinit` logic to get this right.
public final class TextLayoutAttachment {
    /// The layout manager this attachment owns the lifecycle of. Already attached to
    /// `contentStorage` by the time this returns from `init`.
    public let layoutManager: NSTextLayoutManager

    /// Weak, not strong: this attachment's job is to detach from the content storage, not to keep
    /// it alive. If the content storage has already been deallocated (e.g. the whole document was
    /// torn down first), there's nothing left to detach from, and `detach()` below treats that as
    /// already-detached rather than as an error.
    private weak var contentStorage: NSTextContentStorage?

    private var isAttached = true

    /// Creates a fresh `NSTextLayoutManager` and attaches it to `contentStorage` immediately.
    public init(attachingTo contentStorage: NSTextContentStorage) {
        let layoutManager = NSTextLayoutManager()
        self.layoutManager = layoutManager
        self.contentStorage = contentStorage
        contentStorage.addTextLayoutManager(layoutManager)
    }

    /// Detaches `layoutManager` from the content storage it was attached to. Idempotent — safe to
    /// call more than once, and safe to call after the content storage has already been
    /// deallocated (a no-op in that case, since there's nothing left to remove it from).
    public func detach() {
        guard isAttached else { return }
        isAttached = false
        contentStorage?.removeTextLayoutManager(layoutManager)
    }

    deinit {
        detach()
    }
}
