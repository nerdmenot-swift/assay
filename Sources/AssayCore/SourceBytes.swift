//===----------------------------------------------------------------------===//
// Where a Diagnosis's source bytes live.
//
// `Diagnosis` retains the input so that `render(.terminal)` can draw a caret under the
// offending line. For an in-memory parse that is an `[UInt8]` and costs a retain.
//
// For an mmap'd file it must NOT be. Copying a 10 GB mapped file into an array to keep
// carets working would defeat the entire reason for mapping it. So the source can instead
// be a *borrowed* region plus an owner object whose lifetime keeps the mapping alive —
// carets still render, the page faults back in on demand, and resident memory stays
// bounded by what the kernel chooses to keep.
//
// This is the piece that lets docs/STREAMING.md §3.5's mmap finding actually reach the
// error path rather than stopping at the parser.
//===----------------------------------------------------------------------===//

/// The bytes a `Diagnosis` was produced from, retained for rendering.
public struct SourceBytes: @unchecked Sendable {

    @usableFromInline
    enum Storage {
        case owned([UInt8])
        /// A borrowed region. `owner` is retained solely to keep it valid — for a mapped
        /// file that is the `MappedFile` whose `deinit` calls `munmap`.
        case borrowed(base: UnsafeRawPointer, count: Int, owner: AnyObject)
    }

    @usableFromInline
    let storage: Storage

    @inlinable
    public init(_ bytes: [UInt8]) {
        self.storage = .owned(bytes)
    }

    /// Borrow a region whose validity is guaranteed by `owner` staying alive.
    ///
    /// Unsafe in the SE-0458 sense and marked so: the caller asserts that `base`/`count`
    /// remain valid for as long as `owner` is retained. `MappedFile` satisfies that by
    /// construction; nothing else should use this.
    @inlinable
    public init(unsafeBorrowed base: UnsafeRawPointer, count: Int, owner: AnyObject) {
        self.storage = .borrowed(base: base, count: count, owner: owner)
    }

    public static let empty = SourceBytes([])

    public var count: Int {
        switch storage {
        case .owned(let b): return b.count
        case .borrowed(_, let n, _): return n
        }
    }

    /// Scoped access. The pointer is valid only inside `body` — for the owned case because
    /// it comes from `withUnsafeBytes`, and for the borrowed case because that is the
    /// contract this type exists to express.
    public func withUnsafeBytes<R>(
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) rethrows -> R {
        switch storage {
        case .owned(let bytes):
            return try bytes.withUnsafeBytes(body)
        case .borrowed(let base, let count, let owner):
            let buffer = unsafe UnsafeRawBufferPointer(start: base, count: count)
            defer { withExtendedLifetime(owner) {} }
            return try unsafe body(buffer)
        }
    }
}
