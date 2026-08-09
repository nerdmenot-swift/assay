// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The third decode path, measured. docs/KEYED-SOURCE.md.
//
// The design rests on one claim: reaching already-parsed data through the `RawValue` path
// costs an allocation per value per record, and a reader doing millions of rows cannot pay
// it. That was reasoning, not measurement. This is the measurement.
//
// The comparison is between the two things a driver author actually chooses between,
// starting from the SAME native row — a columnar pair of (column names, values), which is
// what a database row and a CSV record really are:
//
//   A. KeyedSource, addressing the row in place.
//   B. Build a `RawValue.mapping` from the row, then decode through the RawValue path.
//
// B is what a driver has to do today. The gap between them is what the third path buys,
// and if there is no gap the path is not worth its generated code.
//
// TWO sources are measured, because the protocol admits both and they are not the same:
//   * `RowSource` compares StaticString keys BYTE-WISE against the column names — no
//     `String` is ever constructed. This is what a real driver would write.
//   * `DictionarySource` (shipped as the reference implementation) hashes a `String` per
//     lookup. Convenient, and deliberately not the fast path — it is included so the
//     difference between "implementable well" and "implemented conveniently" is visible
//     rather than hidden.
//===----------------------------------------------------------------------===//

import Foundation
import Assay

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

/// What a database driver or CSV reader would actually implement: the row stays where it
/// is, and keys are compared as bytes. Nothing is allocated per field.
struct RowSource: KeyedSource, ~Copyable {
    let columns: [[UInt8]]
    let values: [RawValue]

    @inline(__always)
    borrowing func index(_ key: StaticString) -> Int? {
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

    borrowing func has(_ key: StaticString, _ field: Int) -> Bool { index(key) != nil }
    borrowing func isNull(_ key: StaticString, _ field: Int) -> Bool {
        guard let i = index(key) else { return false }
        if case .null = values[i] { return true }
        return false
    }
    borrowing func int64(_ key: StaticString, _ field: Int) -> Int64? { index(key).flatMap { values[$0].int } }
    borrowing func double(_ key: StaticString, _ field: Int) -> Double? { index(key).flatMap { values[$0].double } }
    borrowing func bool(_ key: StaticString, _ field: Int) -> Bool? { index(key).flatMap { values[$0].bool } }
    borrowing func string(_ key: StaticString, _ field: Int) -> String? {
        guard let i = index(key), case .string(let s) = values[i] else { return nil }
        return s
    }
    borrowing func withText<R>(
        _ key: StaticString, _ field: Int, _ body: (UnsafeRawBufferPointer?) -> R
    ) -> R {
        guard let i = index(key), case .string(let s) = values[i] else { return body(nil) }
        var copy = s
        return copy.withUTF8 { unsafe body(UnsafeRawBufferPointer($0)) }
    }
}

/// The same row, BOUND. The plan is resolved once for the whole stream; each record then
/// indexes it. No key is compared, no scan is walked — the key argument is ignored
/// entirely, which is what the second phase buys.
struct BoundRowSource: KeyedSource, ~Copyable {
    let plan: BoundPlan
    let values: [RawValue]

    @inline(__always)
    borrowing func slot(_ field: Int) -> RawValue? {
        let i = plan[field]
        // `Optional<RawValue>.none`, spelled out. A bare `nil` here resolves to
        // `.some(.null)`, because RawValue is ExpressibleByNilLiteral — so an ABSENT
        // column would read as a PRESENT null and a defaulted field would report a type
        // mismatch instead of taking its default. This bit while writing the example.
        guard i != BoundPlan.absent else { return Optional<RawValue>.none }
        return values[i]
    }

    borrowing func has(_ key: StaticString, _ field: Int) -> Bool { slot(field) != nil }
    borrowing func isNull(_ key: StaticString, _ field: Int) -> Bool {
        if case .null? = slot(field) { return true }
        return false
    }
    borrowing func int64(_ key: StaticString, _ field: Int) -> Int64? { slot(field)?.int }
    borrowing func double(_ key: StaticString, _ field: Int) -> Double? { slot(field)?.double }
    borrowing func bool(_ key: StaticString, _ field: Int) -> Bool? { slot(field)?.bool }
    borrowing func string(_ key: StaticString, _ field: Int) -> String? {
        guard case .string(let s)? = slot(field) else { return nil }
        return s
    }
    borrowing func withText<R>(
        _ key: StaticString, _ field: Int, _ body: (UnsafeRawBufferPointer?) -> R
    ) -> R {
        guard case .string(let s)? = slot(field) else { return body(nil) }
        var copy = s
        return copy.withUTF8 { unsafe body(UnsafeRawBufferPointer($0)) }
    }
}

func runSourceBenchmarks() {
    let columnNames = ["id", "name", "email", "age", "score", "active",
                       "created_at", "owner_id"]
    let columns = columnNames.map { Array($0.utf8) }
    let values: [RawValue] = [
        .int(90210), .string("Ada Lovelace"), .string("ada@example.com"),
        .int(36), .double(9.75), .bool(true),
        .string("2026-08-09T12:00:00Z"), .string("owner-7f3a91"),
    ]
    let dict = Dictionary(uniqueKeysWithValues: zip(columnNames, values))

    // What a driver must build TODAY to reach the RawValue path.
    func buildRaw() -> RawValue {
        .mapping(zip(columnNames, values).map { .init(key: $0.0, value: $0.1) })
    }

    print("")
    print("Third decode path — KeyedSource vs materialising a RawValue tree")
    print("Same native row for both: columnar (column names + values), which is what a")
    print("database row and a CSV record are. B is what a driver has to do today.")
    print(pad("approach", 34, right: true) + pad("ns/record", 12)
          + pad("blocks", 10) + pad("bytes", 10))
    print(String(repeating: "-", count: 66))

    let iters = 20_000

    // A. KeyedSource, byte-comparing keys, row addressed in place.
    let aNs = measure(iterations: iters) {
        let src = RowSource(columns: columns, values: values)
        _ = BenchRow.diagnose(source: src).value
    }
    let aAlloc = measureAllocations(iterations: 4_000) { () -> Box<BenchRow>? in
        let src = RowSource(columns: columns, values: values)
        return BenchRow.diagnose(source: src).value.map { Box($0) }
    }

    // B. Build the RawValue mapping, then decode through the RawValue path.
    //
    // Called through the protocol requirement directly: there is no public `parse(raw:)`
    // — the RawValue path is only reachable via the YAML and XML entry points today,
    // which is a small gap of its own and noted in the roadmap.
    func decodeViaRaw() -> BenchRow? {
        var sink = IssueSink()
        return BenchRow._assay(from: buildRaw(), into: &sink, at: [])
    }
    let bNs = measure(iterations: iters) { _ = decodeViaRaw() }
    let bAlloc = measureAllocations(iterations: 4_000) { () -> Box<BenchRow>? in
        decodeViaRaw().map { Box($0) }
    }

    // C. The convenient reference source, which hashes a String per lookup.
    let cNs = measure(iterations: iters) {
        let src = DictionarySource(dict)
        _ = BenchRow.diagnose(source: src).value
    }
    let cAlloc = measureAllocations(iterations: 4_000) { () -> Box<BenchRow>? in
        let src = DictionarySource(dict)
        return BenchRow.diagnose(source: src).value.map { Box($0) }
    }

    // D. THE SHAPE THE DESIGN WAS ACTUALLY FOR: a wide row where the schema wants a few
    //    columns. `SELECT *` against a 48-column table, a CSV with every field the
    //    exporter felt like including. Building a RawValue means materialising every
    //    column; KeyedSource addresses only the eight the schema declared.
    let wideNames = columnNames + (0..<40).map { "spare_\($0)" }
    let wideCols = wideNames.map { Array($0.utf8) }
    let wideValues = values + (0..<40).map { RawValue.string("filler-value-\($0)") }
    let wideDict = Dictionary(uniqueKeysWithValues: zip(wideNames, wideValues))
    func buildWideRaw() -> RawValue {
        .mapping(zip(wideNames, wideValues).map { .init(key: $0.0, value: $0.1) })
    }
    let dNs = measure(iterations: iters) {
        let src = RowSource(columns: wideCols, values: wideValues)
        _ = BenchRow.diagnose(source: src).value
    }
    func decodeWideViaRaw() -> BenchRow? {
        var sink = IssueSink()
        return BenchRow._assay(from: buildWideRaw(), into: &sink, at: [])
    }
    let eNs = measure(iterations: iters) { _ = decodeWideViaRaw() }
    let fNs = measure(iterations: iters) {
        let src = DictionarySource(wideDict)
        _ = BenchRow.diagnose(source: src).value
    }
    let dAlloc = measureAllocations(iterations: 4_000) { () -> Box<BenchRow>? in
        let src = RowSource(columns: wideCols, values: wideValues)
        return BenchRow.diagnose(source: src).value.map { Box($0) }
    }
    let eAlloc = measureAllocations(iterations: 4_000) { () -> Box<BenchRow>? in
        decodeWideViaRaw().map { Box($0) }
    }
    let fAlloc = measureAllocations(iterations: 4_000) { () -> Box<BenchRow>? in
        let src = DictionarySource(wideDict)
        return BenchRow.diagnose(source: src).value.map { Box($0) }
    }

    // The SECOND PHASE: resolve the manifest against the source's columns ONCE, then
    // index it per record. This is the claim the whole design rests on and it has been
    // unmeasured until now.
    let narrowPlan = BoundPlan(manifest: BenchRow._assayManifest, columns: columnNames)
    let widePlan = BoundPlan(manifest: BenchRow._assayManifest, columns: wideNames)
    precondition(narrowPlan.missingRequired(in: BenchRow._assayManifest).isEmpty)
    precondition(widePlan.missingRequired(in: BenchRow._assayManifest).isEmpty)

    let gNs = measure(iterations: iters) {
        let src = BoundRowSource(plan: narrowPlan, values: values)
        _ = BenchRow.diagnose(source: src).value
    }
    let hNs = measure(iterations: iters) {
        let src = BoundRowSource(plan: widePlan, values: wideValues)
        _ = BenchRow.diagnose(source: src).value
    }
    let gAlloc = measureAllocations(iterations: 4_000) { () -> Box<BenchRow>? in
        let src = BoundRowSource(plan: narrowPlan, values: values)
        return BenchRow.diagnose(source: src).value.map { Box($0) }
    }
    let hAlloc = measureAllocations(iterations: 4_000) { () -> Box<BenchRow>? in
        let src = BoundRowSource(plan: widePlan, values: wideValues)
        return BenchRow.diagnose(source: src).value.map { Box($0) }
    }

    func row(_ label: String, _ ns: Double, _ a: (blocks: Double?, bytes: Double)) {
        print(pad(label, 34, right: true)
              + pad(String(format: "%.0f", ns), 12)
              + pad(a.blocks.map { String(format: "%.1f", $0) } ?? "n/a", 10)
              + pad(String(format: "%.0f", a.bytes), 10))
    }
    row("A. KeyedSource (byte-compared)", aNs, aAlloc)
    row("B. build RawValue, then decode", bNs, bAlloc)
    row("C. DictionarySource (hashing)", cNs, cAlloc)
    row("G. BOUND (plan resolved once)", gNs, gAlloc)

    print("")
    print("48-column row, 8 columns declared — SELECT * against a wide table")
    print(pad("approach", 34, right: true) + pad("ns/record", 12)
          + pad("blocks", 10) + pad("bytes", 10))
    print(String(repeating: "-", count: 66))
    row("D. KeyedSource (byte-compared)", dNs, dAlloc)
    row("E. build RawValue, then decode", eNs, eAlloc)
    row("F. DictionarySource (hashing)", fNs, fAlloc)
    row("H. BOUND (plan resolved once)", hNs, hAlloc)

    print("")
    print(String(format: "narrow (8 of 8):  KeyedSource %.2fx the RawValue path", bNs / aNs))
    print(String(format: "wide  (8 of 48):  KeyedSource %.2fx the RawValue path", eNs / dNs))
    print(String(format: "wide, hashing:    DictionarySource %.2fx", eNs / fNs))
    // Binding's real property is not a constant speedup — it is that the cost STOPS
    // DEPENDING ON THE SOURCE'S WIDTH. A scan grows with the columns it walks past; an
    // index does not. 48 columns is too narrow to show it, so widen until it is obvious.
    print("")
    print("Width sensitivity — a scan grows with the table, an index does not")
    print(pad("columns", 12, right: true) + pad("unbound ns", 14) + pad("bound ns", 12)
          + pad("bound wins", 12))
    print(String(repeating: "-", count: 50))
    // The declared columns are INTERLEAVED, evenly spread through the row. Putting them
    // first — the obvious way to build the fixture — makes a scan look free, because it
    // finds every field in the first eight positions and never walks past them. That is a
    // benchmark artifact, not a property of the design, and it is exactly the kind of
    // thing that turns a measurement into an advertisement. A real `SELECT *` scatters the
    // columns you asked for among the ones you did not.
    for width in [8, 48, 128, 400] {
        var names: [String] = []
        var vals: [RawValue] = []
        let stride = max(1, width / 8)
        var declared = 0
        for slot in 0..<width {
            if slot % stride == 0 && declared < 8 {
                names.append(columnNames[declared])
                vals.append(values[declared])
                declared += 1
            } else {
                names.append("spare_\(slot)")
                vals.append(.string("filler-\(slot)"))
            }
        }
        while declared < 8 {
            names.append(columnNames[declared])
            vals.append(values[declared])
            declared += 1
        }
        let cols = names.map { Array($0.utf8) }
        let plan = BoundPlan(manifest: BenchRow._assayManifest, columns: names)
        let u = measure(iterations: 8_000) {
            let src = RowSource(columns: cols, values: vals)
            _ = BenchRow.diagnose(source: src).value
        }
        let b = measure(iterations: 8_000) {
            let src = BoundRowSource(plan: plan, values: vals)
            _ = BenchRow.diagnose(source: src).value
        }
        print(pad("\(width)", 12, right: true)
              + pad(String(format: "%.0f", u), 14)
              + pad(String(format: "%.0f", b), 12)
              + pad(String(format: "%.2fx", u / b), 12))
    }

    print("")
    print("Two-phase binding — the claim the design rests on:")
    print(String(format: "  narrow: bound is %.2fx the unbound scan, %.2fx the RawValue path",
                 aNs / gNs, bNs / gNs))
    print(String(format: "  wide:   bound is %.2fx the unbound scan, %.2fx the RawValue path",
                 dNs / hNs, eNs / hNs))
    print("Blocks are LIVE blocks per decoded value; read Allocations.swift's three stated")
    print("limitations before quoting them. Both sides retain the same String fields, so")
    print("the interesting number is the DIFFERENCE, which is the tree B has to build.")
}
