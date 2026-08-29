// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The columnar batch path, measured. docs/KEYED-SOURCE.md.
//
// This file used to measure a general row-at-a-time `KeyedSource` protocol as well. That
// half was removed once these numbers said it lost to the path it was invented to beat;
// the retired tables are kept in Benchmarks/RESULTS.md rather than deleted, because a
// design that was measured and dropped is more useful written down than forgotten.
//
// What is left is the arm that won, and the two questions it has to answer:
//
//   1. Does inverting the loop pay? Row-by-row over a column store is strided by
//      construction — every record touches all eight column arrays, so N records is N x 8
//      jumps between eight separate allocations. Filling column-by-column makes each one a
//      sequential pass. That is a cache question, so it is measured at sizes that span the
//      caches rather than at one.
//
//   2. Does it survive a driver? The loop that matters lives in a Parquet or Arrow reader,
//      generic over a schema it has never seen, in another module. `@inlinable` on a
//      generated body is forbidden (SE-0193 makes every public @Schema type fail against
//      its own internal memberwise init), so the witness-table call cannot be inlined away.
//      The batch entry point's whole claim is that it pays that once per BATCH rather than
//      once per record.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import ForeignSource

@Schema(keys: .snakeCase, formats: .all, sources: true)
struct BenchRow: Equatable {
    var id: Int
    var name: String
    var email: String
    var age: Int
    var score: Double
    var active: Bool
    var createdAt: String
    var ownerId: String
}

/// A column store: one array per field. What Parquet, Arrow and a column database hand you.
struct BenchColumnStore: ColumnarSource {
    var rowCount: Int
    let ids: [Int64], ages: [Int64]
    let scores: [Double]
    let actives: [Bool]
    let names: [String], emails: [String], createds: [String], owners: [String]

    borrowing func int64Column(_ key: StaticString, _ field: Int) -> [Int64]? {
        switch field { case 0: return ids; case 3: return ages; default: return nil }
    }
    borrowing func doubleColumn(_ key: StaticString, _ field: Int) -> [Double]? {
        field == 4 ? scores : nil
    }
    borrowing func boolColumn(_ key: StaticString, _ field: Int) -> [Bool]? {
        field == 5 ? actives : nil
    }
    borrowing func stringColumn(_ key: StaticString, _ field: Int) -> [String]? {
        switch field {
        case 1: return names; case 2: return emails
        case 6: return createds; case 7: return owners
        default: return nil
        }
    }
}

func makeStore(rows n: Int) -> BenchColumnStore {
    BenchColumnStore(
        rowCount: n,
        ids: (0..<n).map { (i: Int) in Int64(i) },
        ages: (0..<n).map { Int64(20 + $0 % 50) },
        scores: (0..<n).map { Double($0) * 0.5 },
        actives: (0..<n).map { (i: Int) in i % 2 == 0 },
        names: (0..<n).map { "user-\($0)" },
        emails: (0..<n).map { "u\($0)@example.com" },
        createds: (0..<n).map { (_: Int) in "2026-08-09T00:00:00Z" },
        owners: (0..<n).map { "owner-\($0)" })
}

private let columnNames = ["id", "name", "email", "age", "score", "active",
                           "created_at", "owner_id"]

/// The baseline: what a caller reaches the same data through TODAY, one row at a time.
/// A `RawValue.mapping` per record, then the ordinary tree path. This is not a straw man —
/// it is the measured winner over the retired row protocol, at 95 ns against 311 ns.
private func decodeRowwise(_ s: borrowing BenchColumnStore) -> [BenchRow] {
    var out: [BenchRow] = []
    out.reserveCapacity(s.rowCount)
    var sink = IssueSink()
    for r in 0..<s.rowCount {
        let raw = RawValue.mapping([
            .init(key: columnNames[0], value: .int(s.ids[r])),
            .init(key: columnNames[1], value: .string(s.names[r])),
            .init(key: columnNames[2], value: .string(s.emails[r])),
            .init(key: columnNames[3], value: .int(s.ages[r])),
            .init(key: columnNames[4], value: .double(s.scores[r])),
            .init(key: columnNames[5], value: .bool(s.actives[r])),
            .init(key: columnNames[6], value: .string(s.createds[r])),
            .init(key: columnNames[7], value: .string(s.owners[r])),
        ])
        if let v = BenchRow._assay(from: raw, into: &sink, at: []) { out.append(v) }
    }
    return out
}

func runSourceBenchmarks() {
    print("")
    print("Columnar batch fill — row-by-row vs one sequential pass per column")
    print("Baseline is what a caller does today: a RawValue per row, then the tree path.")
    print(pad("rows", 10, right: true) + pad("row-wise ns", 14) + pad("batch ns", 12)
          + pad("per row", 10) + pad("batch wins", 12))
    print(String(repeating: "-", count: 60))

    for n in [64, 1_000, 20_000, 100_000] {
        let store = makeStore(rows: n)
        let reps = max(1, 200_000 / n)
        let rowNs = measure(iterations: reps) {
            precondition(decodeRowwise(store).count == n)
        }
        let batchNs = measure(iterations: reps) {
            let got = BenchRow.batch(from: store)
            precondition(got.values.count == n)
        }
        print(pad("\(n)", 10, right: true)
              + pad(String(format: "%.0f", rowNs), 14)
              + pad(String(format: "%.0f", batchNs), 12)
              + pad(String(format: "%.0f", batchNs / Double(n)), 10)
              + pad(String(format: "%.2fx", rowNs / batchNs), 12))
    }

    // The arrangement that actually matters: the loop lives in the driver, generic over a
    // schema it has never seen and cannot inline. `reader.rows(as: User.self)` is this
    // shape. Per-row, that witness-table call measured 1.6-4.7x on the retired path; the
    // batch entry point should pay it once per batch instead.
    print("")
    print("Cross-module, generic over the schema — where a driver actually lives")
    print(pad("loop location", 34, right: true) + pad("ns/200 rows", 14) + pad("per row", 10))
    print(String(repeating: "-", count: 58))

    let n200 = 200
    let store200 = makeStore(rows: n200)
    let appBatchNs = measure(iterations: 200) {
        var sink = IssueSink()
        let got = BenchRow._assayBatch(from: store200, into: &sink, at: [])
        precondition(got.count == n200)
    }
    let driverBatchNs = measure(iterations: 200) {
        let got = driverDecodeBatch(BenchRow.self, from: store200)
        precondition(got.count == n200)
    }
    print(pad("batch, in the app", 34, right: true)
          + pad(String(format: "%.0f", appBatchNs), 14)
          + pad(String(format: "%.0f", appBatchNs / 200), 10))
    print(pad("batch, in the driver (T generic)", 34, right: true)
          + pad(String(format: "%.0f", driverBatchNs), 14)
          + pad(String(format: "%.0f", driverBatchNs / 200), 10))
    print(String(format: "batch generic-over-schema costs %.2fx", driverBatchNs / appBatchNs))

    print("")
    print("A driver API should be batch-shaped. Being generic over the SCHEMA is the cost,")
    print("not the module boundary, and the batch entry point pays it once per batch.")
    print("Blocks are LIVE blocks per decoded value; read Allocations.swift's three stated")
    print("limitations before quoting them.")
}

// MARK: - The extension point

// What a consumer's own scalar costs, measured against the same data read as a built-in.
//
// The question is the one that killed `KeyedSource`: a protocol call the CONSUMER's loop
// drives cannot be inlined away, because `@inlinable` on a generated body is forbidden
// (SE-0193). The claim here is that `ColumnDecodable` does not have that shape -- the
// generic call is `Column._assayFetch`, made once per COLUMN, and the per-row call names a
// concrete type in the module that declares the schema. If that claim is wrong, the two
// rows of the first table below will not be within noise of each other.

@Schema
struct Micros: Equatable { var v: Int64 }

extension Micros: ColumnDecodable {
    init?(assayColumn c: borrowing ColumnBuffer<Int64>, row: Int, metadata: ColumnMetadata) {
        v = c[row] &* 1_000
    }
}

/// Reads through `range(at:)` and indexes the flat buffer. No allocation, no retain.
@Schema
struct Digest: Equatable { var h: Int64 }

extension Digest: ColumnDecodable {
    init?(assayColumn c: borrowing BytesColumn, row: Int, metadata: ColumnMetadata) {
        guard let r = c.range(at: row) else { return nil }
        var acc: Int64 = 0
        for i in r { acc = acc &* 31 &+ Int64(c.bytes[i]) }
        h = acc
    }
}

/// Identical arithmetic, but materialises the row first. This is precisely the per-row cost
/// a `[[UInt8]]` column would impose on every reader, whether or not it wanted a copy --
/// which is the measurement behind choosing flat-plus-offsets.
@Schema
struct DigestCopying: Equatable { var h: Int64 }

extension DigestCopying: ColumnDecodable {
    init?(assayColumn c: borrowing BytesColumn, row: Int, metadata: ColumnMetadata) {
        guard let b = c.bytes(at: row) else { return nil }
        var acc: Int64 = 0
        for x in b { acc = acc &* 31 &+ Int64(x) }
        h = acc
    }
}

@Schema(sources: true) struct NativeRow: Equatable { var id: Int64; var at: Int64 }
@Schema(sources: true) struct HookRow: Equatable { var id: Int64; var at: Micros }
@Schema(sources: true) struct BytesRow: Equatable { var id: Int64; var d: Digest }
@Schema(sources: true) struct BytesCopyRow: Equatable { var id: Int64; var d: DigestCopying }

struct HookStore: ColumnarSource {
    var rowCount: Int
    let ids: [Int64], ats: [Int64]
    let blob: BytesColumn

    borrowing func int64Column(_ key: StaticString, _ field: Int) -> [Int64]? {
        field == 0 ? ids : ats
    }
    borrowing func doubleColumn(_ key: StaticString, _ field: Int) -> [Double]? { nil }
    borrowing func boolColumn(_ key: StaticString, _ field: Int) -> [Bool]? { nil }
    borrowing func stringColumn(_ key: StaticString, _ field: Int) -> [String]? { nil }
    borrowing func bytesColumn(_ key: StaticString, _ field: Int) -> BytesColumn? { blob }
    borrowing func columnMetadata(_ key: StaticString, _ field: Int) -> ColumnMetadata {
        ColumnMetadata(unit: -6)
    }
}

func runColumnDecodableBenchmarks() {
    print("")
    print("The columnar extension point — a consumer's own scalar vs a built-in column")
    print("Same store, same column, same 2-field schema. The only difference is whether")
    print("the field's type is Int64 or a ColumnDecodable type carried by Int64.")

    let n = 100_000
    let store = HookStore(
        rowCount: n,
        ids: (0..<n).map { Int64($0) },
        ats: (0..<n).map { Int64(1_700_000_000_000_000 + $0) },
        blob: BytesColumn(rows: (0..<n).map { i in
            (0..<16).map { UInt8((i &+ $0) % 256) } }))
    let reps = max(1, 200_000 / n)

    print("")
    print(pad("field type", 34) + pad("ns/batch", 12) + pad("ns/row", 10))
    print(String(repeating: "-", count: 56))

    let native = measure(iterations: reps) {
        precondition(NativeRow.batch(from: store).values.count == n)
    }
    let hook = measure(iterations: reps) {
        precondition(HookRow.batch(from: store).values.count == n)
    }
    print(pad("Int64, built in", 34)
          + pad(String(format: "%.0f", native), 12)
          + pad(String(format: "%.2f", native / Double(n)), 10))
    print(pad("Micros, ColumnDecodable", 34)
          + pad(String(format: "%.0f", hook), 12)
          + pad(String(format: "%.2f", hook / Double(n)), 10))
    print(String(format: "the hook costs %.2f ns/row over the built-in column (%.2fx)",
                 (hook - native) / Double(n), hook / native))

    print("")
    print("Bytes columns — flat-plus-offsets vs materialising each row")
    print("Identical arithmetic over identical bytes; the second one copies the row first,")
    print("which is what a [[UInt8]] column would charge every reader unconditionally.")
    print("")
    print(pad("access", 34) + pad("ns/batch", 12) + pad("ns/row", 10))
    print(String(repeating: "-", count: 56))

    let flat = measure(iterations: reps) {
        precondition(BytesRow.batch(from: store).values.count == n)
    }
    let copying = measure(iterations: reps) {
        precondition(BytesCopyRow.batch(from: store).values.count == n)
    }
    print(pad("range(at:) into the flat buffer", 34)
          + pad(String(format: "%.0f", flat), 12)
          + pad(String(format: "%.2f", flat / Double(n)), 10))
    print(pad("bytes(at:), one Array per row", 34)
          + pad(String(format: "%.0f", copying), 12)
          + pad(String(format: "%.2f", copying / Double(n)), 10))
    print(String(format: "materialising costs %.2f ns/row, %.2fx, at 16 bytes per row",
                 (copying - flat) / Double(n), copying / flat))
}
