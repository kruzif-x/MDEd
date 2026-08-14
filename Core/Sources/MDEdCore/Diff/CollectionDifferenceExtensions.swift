extension CollectionDifference.Change {
    /// The offset this change applies at, regardless of whether it's an insertion or removal.
    ///
    /// `CollectionDifference.Change` is a plain enum with no shared `offset` property of its own
    /// (each case carries its own `offset` associated value) — this extracts it uniformly so
    /// callers can sort/index changes without a `switch` at every use site.
    var offset: Int {
        switch self {
        case .insert(let offset, _, _), .remove(let offset, _, _):
            return offset
        }
    }
}
