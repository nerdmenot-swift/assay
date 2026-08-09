// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// A reference `KeyedSource` over `[String: RawValue]`.
//
// Two jobs. It is genuinely useful — `[String: Any]` from a plist, a form post or a
// driver's row dictionary lands here — and it is the worked example that proves the
// protocol is implementable in a few lines, which is the bar a protocol meant for
// third-party database drivers has to clear.
//
// It is NOT the fast path and does not pretend to be: a `Dictionary` lookup hashes the
// key per field, which is exactly the per-record work the field manifest exists to let a
// real source avoid.
//===----------------------------------------------------------------------===//

public struct DictionarySource: KeyedSource, ~Copyable {
    @usableFromInline let values: [String: RawValue]

    public init(_ values: [String: RawValue]) {
        self.values = values
    }

    @inlinable
    public borrowing func has(_ key: StaticString, _ field: Int) -> Bool {
        values[String(describing: key)] != nil
    }

    @inlinable
    public borrowing func isNull(_ key: StaticString, _ field: Int) -> Bool {
        if case .null = values[String(describing: key)] { return true }
        return false
    }

    @inlinable
    public borrowing func int64(_ key: StaticString, _ field: Int) -> Int64? {
        values[String(describing: key)]?.int
    }

    @inlinable
    public borrowing func double(_ key: StaticString, _ field: Int) -> Double? {
        values[String(describing: key)]?.double
    }

    @inlinable
    public borrowing func bool(_ key: StaticString, _ field: Int) -> Bool? {
        values[String(describing: key)]?.bool
    }

    /// Implemented directly rather than through `withText`: this source is already
    /// holding the `String`, so handing it back is a retain where the default would be a
    /// full copy. Measurement put that copy at most of the third path's cost.
    @inlinable
    public borrowing func string(_ key: StaticString, _ field: Int) -> String? {
        guard case .string(let s)? = values[String(describing: key)] else { return nil }
        return s
    }

    public borrowing func withText<R>(
        _ key: StaticString, _ field: Int, _ body: (UnsafeRawBufferPointer?) -> R
    ) -> R {
        guard case .string(let s)? = values[String(describing: key)] else {
            return body(nil)
        }
        var copy = s
        return copy.withUTF8 { buf in
            unsafe body(UnsafeRawBufferPointer(buf))
        }
    }
}
