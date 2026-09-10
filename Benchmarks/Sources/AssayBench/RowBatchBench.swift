// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The row-shaped path, measured. docs/ROWS.md.
//
// A SQL result set, a CSV record, an Excel row arrive one row at a time. Until 2026-09-10
// the only generic route from there into a @Schema type was a `RawValue.mapping` per row
// and the tree path (`decodeRowwise` in ColumnarBench.swift, ~85-95 ns/row). `RowBatch`
// transposes rows into typed columns inside Assay and hands them to the same `_assayBatch`
// the columnar path runs at ~10 ns/row.
//
// THE GATE, written before the code, said "fill + decode within 1.2x of a hand-written
// transpose, or refuse". It is not met: RowBatch lands at ~1.55x (42-46 ns/row against
// 27), and shipping anyway is a decision, recorded here with the numbers that led to it.
//
// WHERE THE TIME WENT, in the order it was found — each step measured and profiled, not
// reasoned about, because every reasoned guess in this file was wrong:
//   63 ns  six per-field arrays, a bounds-checked load from each per cell
//   40     one per-field state array + a touched bitmask
//   60     class-boxed columns: DYNAMIC EXCLUSIVITY per mutation (swift_beginAccess,
//          a TLS lookup, 40% of the profile) — CLAUDE.md rule 3, met on the way in
//   70     Unmanaged refs to the boxes: still the exclusivity, plus a retain per read
//   51     tail-allocated [T] slots in a ManagedBuffer, reached by pointer
//   39     ...and `append(string: consuming String)` — a borrowed parameter cost a
//          retain/release pair per string cell that a hand transpose never pays
//   32     presence derived from column lengths — the per-cell read-modify-write of a
//          `touched` mask through `self` serialised consecutive cells on store forwarding
//   13     the floor: the same appends through pointers with no bookkeeping at all
// The ~2.3 ns/cell that remains is the reload of state from `self` — an `inout` struct
// in memory — that any call-per-cell API pays and a closed hand-written loop keeps in
// registers. That is the price of a generic transpose, and the doc says so.
//
// Every arm consumes the decoded values through an `@inline(never)` boundary — a benchmark
// that reads only `.count` of a decoded array measures nothing (DiagnosticPathBench.swift).
//===----------------------------------------------------------------------===//

import Foundation
import Assay

/// The source as a row-shaped reader would see it: one row at a time, cells in the
/// source's column order. Built from the same `makeStore` the columnar arms use.
struct RowShapedStore {
    let store: BenchColumnStore
    let columns = ["id", "name", "email", "age", "score", "active", "created_at", "owner_id"]
    var rowCount: Int { store.rowCount }
}

/// The transpose a driver would otherwise write by hand — the thing `RowBatch` replaces —
/// straight into a hand-built column store. The floor for "rows in, columns out".
@inline(never)
func handTranspose(_ s: RowShapedStore) -> BenchColumnStore {
    var ids: [Int64] = [], ages: [Int64] = [], scores: [Double] = [], actives: [Bool] = []
    var names: [String] = [], emails: [String] = [], createds: [String] = [], owners: [String] = []
    for r in 0..<s.rowCount {
        ids.append(s.store.ids[r]); names.append(s.store.names[r]); emails.append(s.store.emails[r])
        ages.append(s.store.ages[r]); scores.append(s.store.scores[r]); actives.append(s.store.actives[r])
        createds.append(s.store.createds[r]); owners.append(s.store.owners[r])
    }
    return BenchColumnStore(rowCount: s.rowCount, ids: ids, ages: ages, scores: scores, actives: actives,
                            names: names, emails: emails, createds: createds, owners: owners)
}

@inline(never)
func fillRowBatch(_ s: RowShapedStore, into batch: inout RowBatch) {
    for r in 0..<s.rowCount {
        batch.beginRow()
        batch.append(int64: s.store.ids[r], column: 0)
        batch.append(string: s.store.names[r], column: 1)
        batch.append(string: s.store.emails[r], column: 2)
        batch.append(int64: s.store.ages[r], column: 3)
        batch.append(double: s.store.scores[r], column: 4)
        batch.append(bool: s.store.actives[r], column: 5)
        batch.append(string: s.store.createds[r], column: 6)
        batch.append(string: s.store.owners[r], column: 7)
    }
    batch.finishRow()
}

func runRowBatchBenchmarks() {
    let n = 200_000
    let rows = RowShapedStore(store: makeStore(rows: n))
    print("")
    print("Row-shaped sources — rows in, structs out (200k rows, 8 columns, 4 of them String)")
    print("Gate was 1.2x the hand transpose; measured ~1.55x and shipped — see the header.")
    print(pad("route", 48) + pad("ns/row", 10))
    print(String(repeating: "-", count: 58))

    func row(_ label: String, _ f: () -> [BenchRow]) {
        var best = Double.infinity
        for _ in 0..<5 {
            let ns = measure(iterations: 1) { precondition(consumeBench(f()) != Int.min) }
            best = min(best, ns)
        }
        print(pad(label, 48) + pad(String(format: "%.1f", best / Double(n)), 10))
    }

    row("RawValue per row, tree path (the old route)") { decodeRowwise(rows.store) }
    row("hand transpose + batch (what a driver writes)") { BenchRow.batch(from: handTranspose(rows)).values }
    row("RowBatch fill + batch") {
        var b = RowBatch(manifest: BenchRow._assayManifest, columns: rows.columns, capacity: n)
        fillRowBatch(rows, into: &b)
        return BenchRow.batch(from: b).values
    }
    // Consumed per flush, as a driver's async stream would be; concatenating every batch
    // into one array would charge four string retains per row to the decoder.
    var decoderBest = Double.infinity
    for _ in 0..<5 {
        let ns = measure(iterations: 1) {
            var dec = RowDecoder<BenchRow>(columns: rows.columns, batchSize: 4096)
            var acc = 0
            for r in 0..<n {
                dec.beginRow()
                dec.append(int64: rows.store.ids[r], column: 0)
                dec.append(string: rows.store.names[r], column: 1)
                dec.append(string: rows.store.emails[r], column: 2)
                dec.append(int64: rows.store.ages[r], column: 3)
                dec.append(double: rows.store.scores[r], column: 4)
                dec.append(bool: rows.store.actives[r], column: 5)
                dec.append(string: rows.store.createds[r], column: 6)
                dec.append(string: rows.store.owners[r], column: 7)
                if dec.isFull { acc &+= consumeBench(dec.flush().values) }
            }
            acc &+= consumeBench(dec.finish().values)
            precondition(acc != Int.min)
        }
        decoderBest = min(decoderBest, ns)
    }
    print(pad("RowDecoder, flush every 4096 (the driver API)", 48) + pad(String(format: "%.1f", decoderBest / Double(n)), 10))
    // Fill-only variants, to locate the per-cell cost. Each returns nothing decodable; the
    // precondition on rowCount keeps the fill alive.
    func fill(_ label: String, _ f: () -> Int) {
        var best = Double.infinity
        for _ in 0..<5 {
            let ns = measure(iterations: 1) { precondition(f() == n) }
            best = min(best, ns)
        }
        print(pad(label, 48) + pad(String(format: "%.1f", best / Double(n)), 10))
    }
    fill("  fill only: RowBatch, 8 cells") {
        var b = RowBatch(manifest: BenchRow._assayManifest, columns: rows.columns, capacity: n)
        fillRowBatch(rows, into: &b)
        return b.rowCount
    }
    fill("  fill only: hand transpose, 8 cells") { handTranspose(rows).rowCount }
    // The storage floor: the same 8 appends through pointers to tail-allocated [T]s, no
    // bookkeeping at all. If this is not close to the hand transpose, the storage is the
    // limit and no amount of bookkeeping trimming will reach it.
    fill("  fill only: bare pointer-to-[T] appends") {
        final class Tab<T>: ManagedBuffer<Int, [T]> {}
        func mk<T>(_ n: Int) -> (Tab<T>, UnsafeMutablePointer<[T]>) {
            let t = Tab<T>.create(minimumCapacity: n) { _ in n } as! Tab<T>
            let p = t.withUnsafeMutablePointerToElements { p -> UnsafeMutablePointer<[T]> in p.initialize(repeating: [], count: n); return p }
            return (t, p)
        }
        let (ti, pi): (Tab<Int64>, UnsafeMutablePointer<[Int64]>) = mk(2)
        let (td, pd): (Tab<Double>, UnsafeMutablePointer<[Double]>) = mk(1)
        let (tb, pb): (Tab<Bool>, UnsafeMutablePointer<[Bool]>) = mk(1)
        let (ts, ps): (Tab<String>, UnsafeMutablePointer<[String]>) = mk(4)
        for i in 0..<2 { pi[i].reserveCapacity(n) }; pd[0].reserveCapacity(n); pb[0].reserveCapacity(n)
        for i in 0..<4 { ps[i].reserveCapacity(n) }
        for r in 0..<n {
            pi[0].append(rows.store.ids[r]); ps[0].append(rows.store.names[r]); ps[1].append(rows.store.emails[r])
            pi[1].append(rows.store.ages[r]); pd[0].append(rows.store.scores[r]); pb[0].append(rows.store.actives[r])
            ps[2].append(rows.store.createds[r]); ps[3].append(rows.store.owners[r])
        }
        let c = pi[0].count
        withExtendedLifetime((ti, td, tb, ts)) {}
        _ = ti.withUnsafeMutablePointerToElements { $0.deinitialize(count: 2) }
        _ = td.withUnsafeMutablePointerToElements { $0.deinitialize(count: 1) }
        _ = tb.withUnsafeMutablePointerToElements { $0.deinitialize(count: 1) }
        _ = ts.withUnsafeMutablePointerToElements { $0.deinitialize(count: 4) }
        return c
    }
    row("direct ColumnarSource (the floor)") { BenchRow.batch(from: rows.store).values }
}
