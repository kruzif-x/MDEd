import AppKit
import Testing
@testable import MDEdCore

/// Regression coverage for the attach/detach lifecycle bug described in
/// `TextLayoutAttachment`'s doc comment: several views sharing one document's
/// `NSTextContentStorage` each attached their own `NSTextLayoutManager`, but nothing detached it
/// again when the view went away, leaking one stale layout manager per closed window. This is
/// exactly the "open → close → reopen" path that's easy to under-test since it normally requires
/// driving real windows — `TextLayoutAttachment` factors the attach/detach bookkeeping out into
/// something plain `NSTextContentStorage`/`NSTextLayoutManager` calls can verify headlessly.
@Suite("TextLayoutAttachment")
struct TextLayoutAttachmentTests {

    @Test func attachingRegistersTheLayoutManagerImmediately() {
        let contentStorage = NSTextContentStorage()
        let attachment = TextLayoutAttachment(attachingTo: contentStorage)

        #expect(contentStorage.textLayoutManagers.count == 1)
        #expect(contentStorage.textLayoutManagers.first === attachment.layoutManager)
    }

    @Test func deallocatingTheAttachmentDetachesItsLayoutManager() {
        let contentStorage = NSTextContentStorage()

        do {
            let attachment = TextLayoutAttachment(attachingTo: contentStorage)
            #expect(contentStorage.textLayoutManagers.count == 1)
            _ = attachment // silence "never used" — its lifetime is the point of this test
        }

        #expect(contentStorage.textLayoutManagers.isEmpty)
    }

    /// The exact scenario the leak this type fixes came from: several views (an editor tab, one
    /// or more comparison panes) attaching to the *same* document's content storage over time.
    /// Each attachment's own deinit must detach only its own layout manager, never a sibling's.
    @Test func multipleAttachmentsDetachIndependently() {
        let contentStorage = NSTextContentStorage()

        var first: TextLayoutAttachment? = TextLayoutAttachment(attachingTo: contentStorage)
        let second = TextLayoutAttachment(attachingTo: contentStorage)
        #expect(contentStorage.textLayoutManagers.count == 2)

        first = nil
        #expect(contentStorage.textLayoutManagers.count == 1)
        #expect(contentStorage.textLayoutManagers.first === second.layoutManager)

        second.detach()
        #expect(contentStorage.textLayoutManagers.isEmpty)
    }

    /// Repeated open/close cycles of the same document (the scenario called out as under-tested)
    /// must never leave more than one layout manager attached at a time — this is the "stale
    /// layout managers accumulate across window lifecycles" failure mode, reproduced headlessly.
    @Test func repeatedOpenCloseCyclesDoNotAccumulateLayoutManagers() {
        let contentStorage = NSTextContentStorage()

        for _ in 0..<25 {
            let attachment = TextLayoutAttachment(attachingTo: contentStorage)
            #expect(contentStorage.textLayoutManagers.count == 1)
            _ = attachment
        }

        #expect(contentStorage.textLayoutManagers.isEmpty)
    }

    @Test func detachIsIdempotent() {
        let contentStorage = NSTextContentStorage()
        let attachment = TextLayoutAttachment(attachingTo: contentStorage)

        attachment.detach()
        attachment.detach()
        attachment.detach()

        #expect(contentStorage.textLayoutManagers.isEmpty)
    }

    /// If the content storage itself is torn down first (e.g. the whole document closed before
    /// this particular view finished deallocating), detaching from it afterward must be a no-op,
    /// not a crash — `contentStorage` here is intentionally allowed to deallocate while
    /// `attachment` is still alive.
    @Test func detachAfterContentStorageIsDeallocatedIsSafe() {
        var contentStorage: NSTextContentStorage? = NSTextContentStorage()
        let attachment = TextLayoutAttachment(attachingTo: contentStorage!)

        contentStorage = nil
        _ = contentStorage

        attachment.detach() // must not crash
    }
}
