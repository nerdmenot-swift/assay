// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The write side of the row path. docs/ROWS.md §D.
//
// WHAT THIS IS NOT: a CSV writer, an INSERT builder, a Parquet encoder. Those stay in the
// library that owns the format. WHAT IT IS: the one thing such a library cannot write —
// getting the field values OUT of a `@Schema` value in declaration order, because only the
// macro knows the fields. Until 2026-09-11 that was `_assayEncodeRaw` (a `RawValue` tree,
// ~50 ns/row, which haul measured as 50 of its CSV writer's 61) or the developer restating
// the field list by hand, which is how haul's silent column-swap bug was made.
//
// `@Schema(encodes: true, sources: true)` emits one line per field handing the value to
// whatever `RowSink` the caller passes: six methods that append bytes, or bound SQL
// parameters, or Parquet cells. Column names are `_assayManifest.keys`. No tree.
//===----------------------------------------------------------------------===//

/// Where a row's cells go, one call per field in manifest order. Implemented by whoever
/// owns the output — a CSV line, a parameter list, a column store.
public protocol RowSink: ~Copyable {
    mutating func write(int64: Int64, _ field: Int)
    mutating func write(double: Double, _ field: Int)
    mutating func write(bool: Bool, _ field: Int)
    mutating func write(string: String, _ field: Int)
    /// Borrowed for the call only; copy it if you keep it.
    mutating func write(bytes: UnsafeRawBufferPointer, _ field: Int)
    mutating func writeNull(_ field: Int)
}

/// A consumer's own scalar on the way out — the inverse of `ColumnDecodable`. One
/// requirement: hand the value to the sink as one of its primitives. Generic over the
/// sink, so it is a witness call per custom field per row; the built-in scalars are direct.
public protocol ColumnEncodable {
    func assayWrite<S: RowSink & ~Copyable>(into sink: inout S, field: Int)
}

extension Array: ColumnEncodable where Element == UInt8 {
    @inlinable
    public func assayWrite<S: RowSink & ~Copyable>(into sink: inout S, field: Int) {
        unsafe withUnsafeBytes { unsafe sink.write(bytes: $0, field) }
    }
}

/// A `Date` field writes what its primary `@DateFormat` renders — ISO-8601 text, or a
/// unix number — so what is written is what the column path reads back (text dates,
/// docs/ROWS.md §C). Called by generated code with the epoch seconds; `Date` itself is
/// never named here.
@_documentation(visibility: internal)
@inlinable
public func _assayWriteDate<S: RowSink & ~Copyable>(
    _ seconds: Double, _ formats: [DateFormat], into sink: inout S, _ field: Int
) {
    switch _assayRawDate(seconds, formats) {
    case .string(let s): sink.write(string: s, field)
    case .int(let i): sink.write(int64: i, field)
    case .double(let d): sink.write(double: d, field)
    default: sink.writeNull(field)
    }
}

// MARK: - RowBatch as a sink

/// A batch bound positionally (`BoundPlan(slots: 0..<n)`) is a sink for its own manifest:
/// `beginRow()`, `value.encodeRow(into: &batch)`, and the batch decodes back. The round
/// trip the tests hold the write side to.
extension RowBatch: RowSink {
    @inlinable public mutating func write(int64 v: Int64, _ field: Int) { append(int64: v, column: field) }
    @inlinable public mutating func write(double v: Double, _ field: Int) { append(double: v, column: field) }
    @inlinable public mutating func write(bool v: Bool, _ field: Int) { append(bool: v, column: field) }
    @inlinable public mutating func write(string v: String, _ field: Int) { append(string: v, column: field) }
    @inlinable public mutating func write(bytes v: UnsafeRawBufferPointer, _ field: Int) { unsafe append(bytes: v, column: field) }
    @inlinable public mutating func writeNull(_ field: Int) { appendNull(column: field) }
}
