// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The eagerly-built diagnostic path. FIXED 2026-09-10 — and this header used to say
// "RESOLVED 2026-09-07, no change needed", which was wrong. Both versions are worth
// having, so the old claim is kept below the new record.
//
// WHAT IS TRUE NOW. The generated row loop no longer builds a path per row at all: it
// writes two integers into the sink (`IssueSink._enterRow`) and `sink.add`, cold, inserts
// the row index into whatever is reported. The arms below are unchanged and the real body
// sits with the lazy hand-rolled one, where the earlier record claimed it already was:
//
//     concrete, eager (the old shape)                ~57 ns/row
//     concrete, in the failure branch                ~16
//     real _assayBatch, called concretely            ~13     (was ~54 before the fix)
//     real, via batch(from:)                         ~15     (was ~57)
//
// WHAT THE OLD RECORD SAID, AND WHY IT WAS WRONG. It measured the same arms, found the
// eager/lazy gap (56 vs 13), then reported the real generated body at ~14 ns/row "with the
// eager spelling" and the lazy macro change as byte-identical machine code, and reverted
// it. On the tree of 2026-09-10 the real body measured 52–54 ns/row in this very arm and in
// the new `colfloor` arm, with values consumed — the eager number. Whatever build that
// ~14 was read from, it was not the shipped body's steady state, and a disassembly
// comparison of two hand-rolled functions says nothing about the generated one. The
// claim was also wrong for the case the reverted change had excluded: a schema with rules
// kept the per-row binding on purpose, so it could never have been "already optimised".
//
// The methodological point the old header made still holds and is why this file stays: a
// benchmark that observes only `.count` of the decoded array measures nothing (every arm
// here consumes the rows through `consumeRows`), and a hand-rolled reproduction needs
// `@inline(never)` to be measured at all. What it got wrong was trusting a disassembly diff
// of the reproduction over a measurement of the product.
//===----------------------------------------------------------------------===//

import Assay

@Schema(sources: true)
struct PRow: Equatable { var a: Int64; var b: Double; var c: String }

struct PStore: ColumnarSource {
    var rowCount: Int
    let ints: [Int64], dbls: [Double], strs: [String]
    borrowing func int64Column(_ k: StaticString, _ f: Int) -> [Int64]? { ints }
    borrowing func doubleColumn(_ k: StaticString, _ f: Int) -> [Double]? { dbls }
    borrowing func boolColumn(_ k: StaticString, _ f: Int) -> [Bool]? { nil }
    borrowing func stringColumn(_ k: StaticString, _ f: Int) -> [String]? { strs }
}

// Hand-rolled copies of the emitted loop, differing ONLY in where the row path is built.
@inline(never)
func pathEagerG<C: ColumnarSource & ~Copyable>(_ s: borrowing C, _ sink: inout IssueSink, _ path: [PathComponent]) -> [PRow] {
    let c0 = s.int64Column("a", 0), c1 = s.doubleColumn("b", 1), c2 = s.stringColumn("c", 2)
    let n0 = s.nulls("a", 0), n1 = s.nulls("b", 1), n2 = s.nulls("c", 2)
    var out: [PRow] = []; out.reserveCapacity(s.rowCount)
    for r in 0..<s.rowCount {
        let path = path + [.index(r)]
        var f0: Int64? = nil
        if let col = c0, r < col.count, !_assayIsNullAt(n0, r) { f0 = col[r] }
        var f1: Double? = nil
        if let col = c1, r < col.count, !_assayIsNullAt(n1, r) { f1 = col[r] }
        var f2: String? = nil
        if let col = c2, r < col.count, !_assayIsNullAt(n2, r) { f2 = col[r] }
        guard let v0 = f0 else { _assayRowMissing(&sink, path, "a"); continue }
        guard let v1 = f1 else { _assayRowMissing(&sink, path, "b"); continue }
        guard let v2 = f2 else { _assayRowMissing(&sink, path, "c"); continue }
        out.append(PRow(a: v0, b: v1, c: v2))
    }
    return out
}

@inline(never)
func pathLazyG<C: ColumnarSource & ~Copyable>(_ s: borrowing C, _ sink: inout IssueSink, _ path: [PathComponent]) -> [PRow] {
    let c0 = s.int64Column("a", 0), c1 = s.doubleColumn("b", 1), c2 = s.stringColumn("c", 2)
    let n0 = s.nulls("a", 0), n1 = s.nulls("b", 1), n2 = s.nulls("c", 2)
    var out: [PRow] = []; out.reserveCapacity(s.rowCount)
    for r in 0..<s.rowCount {
        var f0: Int64? = nil
        if let col = c0, r < col.count, !_assayIsNullAt(n0, r) { f0 = col[r] }
        var f1: Double? = nil
        if let col = c1, r < col.count, !_assayIsNullAt(n1, r) { f1 = col[r] }
        var f2: String? = nil
        if let col = c2, r < col.count, !_assayIsNullAt(n2, r) { f2 = col[r] }
        guard let v0 = f0 else { _assayRowMissing(&sink, path + [.index(r)], "a"); continue }
        guard let v1 = f1 else { _assayRowMissing(&sink, path + [.index(r)], "b"); continue }
        guard let v2 = f2 else { _assayRowMissing(&sink, path + [.index(r)], "c"); continue }
        out.append(PRow(a: v0, b: v1, c: v2))
    }
    return out
}

@inline(never)
func pathEager(_ s: borrowing PStore, _ sink: inout IssueSink, _ path: [PathComponent]) -> [PRow] {
    let c0 = s.int64Column("a", 0), c1 = s.doubleColumn("b", 1), c2 = s.stringColumn("c", 2)
    let n0 = s.nulls("a", 0), n1 = s.nulls("b", 1), n2 = s.nulls("c", 2)
    var out: [PRow] = []; out.reserveCapacity(s.rowCount)
    for r in 0..<s.rowCount {
        let path = path + [.index(r)]
        var f0: Int64? = nil
        if let col = c0, r < col.count, !_assayIsNullAt(n0, r) { f0 = col[r] }
        var f1: Double? = nil
        if let col = c1, r < col.count, !_assayIsNullAt(n1, r) { f1 = col[r] }
        var f2: String? = nil
        if let col = c2, r < col.count, !_assayIsNullAt(n2, r) { f2 = col[r] }
        guard let v0 = f0 else { _assayRowMissing(&sink, path, "a"); continue }
        guard let v1 = f1 else { _assayRowMissing(&sink, path, "b"); continue }
        guard let v2 = f2 else { _assayRowMissing(&sink, path, "c"); continue }
        out.append(PRow(a: v0, b: v1, c: v2))
    }
    return out
}

@inline(never)
func pathLazy(_ s: borrowing PStore, _ sink: inout IssueSink, _ path: [PathComponent]) -> [PRow] {
    let c0 = s.int64Column("a", 0), c1 = s.doubleColumn("b", 1), c2 = s.stringColumn("c", 2)
    let n0 = s.nulls("a", 0), n1 = s.nulls("b", 1), n2 = s.nulls("c", 2)
    var out: [PRow] = []; out.reserveCapacity(s.rowCount)
    for r in 0..<s.rowCount {
        var f0: Int64? = nil
        if let col = c0, r < col.count, !_assayIsNullAt(n0, r) { f0 = col[r] }
        var f1: Double? = nil
        if let col = c1, r < col.count, !_assayIsNullAt(n1, r) { f1 = col[r] }
        var f2: String? = nil
        if let col = c2, r < col.count, !_assayIsNullAt(n2, r) { f2 = col[r] }
        guard let v0 = f0 else { _assayRowMissing(&sink, path + [.index(r)], "a"); continue }
        guard let v1 = f1 else { _assayRowMissing(&sink, path + [.index(r)], "b"); continue }
        guard let v2 = f2 else { _assayRowMissing(&sink, path + [.index(r)], "c"); continue }
        out.append(PRow(a: v0, b: v1, c: v2))
    }
    return out
}

// Everything below observed only `.count`, which leaves the optimiser free to discard work
// whose result is never read. This forces the decoded values to be live: opaque to the
// caller, and it touches all three fields so none of them can be elided.
@inline(never)
func consumeRows(_ rows: [PRow]) -> Int {
    var acc = 0
    for r in rows { acc &+= Int(truncatingIfNeeded: r.a) ^ Int(r.b) ^ r.c.count }
    return acc
}

func runPathAB() {
    let n = 200_000
    let store = PStore(rowCount: n,
                       ints: (0..<n).map { Int64($0) },
                       dbls: (0..<n).map { Double($0) },
                       strs: (0..<n).map { "s-\($0)" })
    print("")
    print("Diagnostic path: is building it eagerly costing anything? (200k rows, 3 columns)")
    print("The two hand-rolled arms differ ONLY in where the row path is built. The real")
    print("body builds none and should sit with the cheap arm -- see the header.")
    print(pad("variant", 44) + pad("ns/row", 10))
    print(String(repeating: "-", count: 54))
    for (label, f) in [("concrete, eager (the old shape)", pathEager),
                       ("concrete, in the failure branch", pathLazy)] {
        let ns = measure(iterations: 1) {
            var sink = IssueSink(limits: .default)
            precondition(consumeRows(f(store, &sink, [])) != Int.min)
        }
        print(pad(label, 44) + pad(String(format: "%.2f", ns / Double(n)), 10))
    }
    // The real body is GENERIC over the source, which is the shape that matters.
    let ge = measure(iterations: 1) {
        var sink = IssueSink(limits: .default)
        precondition(consumeRows(pathEagerG(store, &sink, [])) != Int.min)
    }
    print(pad("generic, eager (the real body's shape)", 44)
          + pad(String(format: "%.2f", ge / Double(n)), 10))
    let gl = measure(iterations: 1) {
        var sink = IssueSink(limits: .default)
        precondition(consumeRows(pathLazyG(store, &sink, [])) != Int.min)
    }
    print(pad("generic, in the failure branch", 44)
          + pad(String(format: "%.2f", gl / Double(n)), 10))
    let real = measure(iterations: 1) {
        precondition(consumeRows(PRow.batch(from: store).values) != Int.min)
    }
    print(pad("real, via batch(from:) [protocol ext]", 44)
          + pad(String(format: "%.2f", real / Double(n)), 10))
    // Same body, called directly on the concrete type — no witness table in the way.
    let direct = measure(iterations: 1) {
        var sink = IssueSink(limits: .default)
        precondition(consumeRows(PRow._assayBatch(from: store, into: &sink, at: [])) != Int.min)
    }
    print(pad("real _assayBatch, called concretely", 44)
          + pad(String(format: "%.2f", direct / Double(n)), 10))
}
