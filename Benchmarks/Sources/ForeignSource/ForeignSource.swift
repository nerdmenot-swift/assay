// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// A `KeyedSource` in a DIFFERENT MODULE from the schema that consumes it.
//
// This exists to settle a claim docs/KEYED-SOURCE.md makes and never checked: that the
// generic entry point `_assay<S: KeyedSource>` specialises within a module and falls back
// to witness-table dispatch across one — which is exactly where a real Postgres, SQLite or
// Parquet driver lives.
//
// If the claim is true, the ergonomic API is slow in the only configuration that matters,
// and the design has a hole. Measured rather than assumed.
//===----------------------------------------------------------------------===//

public import Assay

/// The same shape as the in-module benchmark source, deliberately: the only variable under
/// test is which module it was compiled in.
public struct ForeignRowSource: KeyedSource, ~Copyable {
    public let columns: [[UInt8]]
    public let values: [RawValue]

    public init(columns: [[UInt8]], values: [RawValue]) {
        self.columns = columns
        self.values = values
    }

    @inline(__always)
    public borrowing func index(_ key: StaticString) -> Int? {
        let n = key.utf8CodeUnitCount
        let p = key.utf8Start
        for (i, c) in columns.enumerated() where c.count == n {
            var same = true
            var j = 0
            while j < n {
                let pb = unsafe p[j]
                if c[j] != pb { same = false; break }
                j += 1
            }
            if same { return i }
        }
        return nil
    }

    public borrowing func has(_ key: StaticString, _ field: Int) -> Bool {
        index(key) != nil
    }
    public borrowing func isNull(_ key: StaticString, _ field: Int) -> Bool {
        guard let i = index(key) else { return false }
        if case .null = values[i] { return true }
        return false
    }
    public borrowing func int64(_ key: StaticString, _ field: Int) -> Int64? {
        index(key).flatMap { values[$0].int }
    }
    public borrowing func double(_ key: StaticString, _ field: Int) -> Double? {
        index(key).flatMap { values[$0].double }
    }
    public borrowing func bool(_ key: StaticString, _ field: Int) -> Bool? {
        index(key).flatMap { values[$0].bool }
    }
    public borrowing func string(_ key: StaticString, _ field: Int) -> String? {
        guard let i = index(key), case .string(let s) = values[i] else { return nil }
        return s
    }
    public borrowing func withText<R>(
        _ key: StaticString, _ field: Int, _ body: (UnsafeRawBufferPointer?) -> R
    ) -> R {
        guard let i = index(key), case .string(let s) = values[i] else { return body(nil) }
        var copy = s
        return copy.withUTF8 { unsafe body(UnsafeRawBufferPointer($0)) }
    }
}

/// What a driver actually offers: `db.query("SELECT …", as: User.self)`.
///
/// This is the arrangement that matters, and it is NOT the one a naive cross-module test
/// measures. Putting the *source* in another module changes nothing, because the generated
/// `_assay<S>` lives in the schema's module and so does the call site — the compiler sees
/// both concrete types and specialises.
///
/// Here the loop lives in the DRIVER, generic over a schema it has never seen. `_assay` is
/// in the caller's module, non-inlinable (SE-0193 forbids `@inlinable` on a generated
/// body), and `T` is unknown — so if specialisation is going to fail anywhere, it fails
/// here, and this is the shape every real driver API takes.
public func driverDecodeAll<T: SourceDecodable>(
    _ type: T.Type,
    columns: [[UInt8]],
    rows: [[RawValue]]
) -> [T] {
    var out: [T] = []
    out.reserveCapacity(rows.count)
    var sink = IssueSink()
    for r in rows {
        let src = ForeignRowSource(columns: columns, values: r)
        if let v = T._assay(from: src, into: &sink, at: []) { out.append(v) }
    }
    return out
}

/// The same driver API, but batch-shaped: the driver hands over a whole column batch and
/// the generated `_assayBatch` does the looping.
///
/// The generic dispatch then happens ONCE, not once per row, because the per-row loop
/// lives inside a function that is concrete in the schema's own module. If that is what
/// the 1.48x per-row cost is made of, this should erase it.
public func driverDecodeBatch<T: SourceDecodable, C: ColumnarSource & ~Copyable>(
    _ type: T.Type,
    from source: borrowing C
) -> [T] {
    var sink = IssueSink()
    return T._assayBatch(from: source, into: &sink, at: [])
}
