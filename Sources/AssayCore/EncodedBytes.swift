// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// What an encoder returns: the bytes it wrote, and nothing else.
//
// WHY THIS EXISTS, AND WHY IT IS NOT `[UInt8]`. A writer that accumulates into an `Array`
// pays a uniqueness check on every write, because `Array` cannot know the writer is its only
// owner: 36,004 of them per `base/encode` call, about 12-18% of the call, after the run and
// key-literal work of `docs/EFFICIENCY.md` rows 5 and 22. Owning the buffer removes every one
// of those checks — a write becomes a store — but then handing `[UInt8]` back means copying
// the whole document into a fresh Array at the end, which is one extra block and one extra
// copy of the output per encode. That trade fails the decision rule: resource counters come
// first.
//
// So the encoders return the buffer itself. `finish()` transfers ownership (`discard self`),
// this type frees it, and nothing is copied anywhere on the way out.
//
// It is `~Copyable` because it owns a heap allocation and must free it exactly once. That is
// the cost of the design and it is a real one: an `EncodedBytes` cannot be stored in two
// places, put in an `Array`, or captured by an escaping closure. `toArray()` is the way out
// for a caller who needs those things, and it copies, visibly, where the caller asked for it.
//
// `EncodeDiagnosis` deliberately keeps `[UInt8]`: that is the diagnostic path, callers store
// and pass it around, and one copy there buys an ordinary `Sendable` struct.
//===----------------------------------------------------------------------===//

/// The bytes an encoder wrote.
///
/// ```swift
/// let bytes = try user.encodedJSON()
/// bytes.withUnsafeBytes { try? socket.write($0) }   // no copy
/// let array = try user.encodedJSON().toArray()      // one copy, where you asked for it
/// ```
@safe
public struct EncodedBytes: ~Copyable {

    /// Owned. Nil only for the empty case, which allocates nothing.
    @usableFromInline var storage: UnsafeMutablePointer<UInt8>?

    /// How many bytes were written. The allocation may be larger; nothing outside sees it.
    public let count: Int

    /// Takes ownership of `storage`, which must hold at least `count` initialised bytes and
    /// must have come from `UnsafeMutablePointer<UInt8>.allocate`.
    @usableFromInline
    init(taking storage: UnsafeMutablePointer<UInt8>?, count: Int) {
        unsafe self.storage = storage
        self.count = count
    }

    /// No bytes, no allocation.
    @inlinable
    public init() {
        unsafe self.storage = nil
        self.count = 0
    }

    /// The UTF-8 of `text`, copied into an owned buffer.
    ///
    /// For a writer that accumulates a `String` rather than bytes — `YAML.encode` does, and
    /// has always copied once at the end. No pointer appears in this signature, which is the
    /// constraint CLAUDE.md rule 11 puts on the public surface.
    public init(text: String) {
        var text = text
        var storage: UnsafeMutablePointer<UInt8>? = nil
        var count = 0
        text.withUTF8 { bytes in
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            unsafe p.update(from: base, count: bytes.count)
            unsafe storage = p
            count = bytes.count
        }
        unsafe self.storage = storage
        self.count = count
    }

    @inlinable
    public var isEmpty: Bool { count == 0 }

    /// The bytes, borrowed. Nothing is copied; the buffer is valid for the call.
    @inlinable
    public func withUnsafeBytes<R>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
        guard let storage = unsafe storage else {
            return try unsafe body(UnsafeBufferPointer(start: nil, count: 0))
        }
        return try unsafe body(UnsafeBufferPointer(start: storage, count: count))
    }

    /// A copy, for a caller who needs a value type. The one place this design copies, and it
    /// is where the caller asked for it.
    @inlinable
    public consuming func toArray() -> [UInt8] {
        let out = unsafe withUnsafeBytes { unsafe Array($0) }
        return out
    }

    /// The bytes as text. Every writer emits valid UTF-8, so this cannot repair.
    @inlinable
    public func text() -> String {
        unsafe withUnsafeBytes { unsafe String(decoding: $0, as: UTF8.self) }
    }

    deinit {
        unsafe storage?.deallocate()
    }
}
