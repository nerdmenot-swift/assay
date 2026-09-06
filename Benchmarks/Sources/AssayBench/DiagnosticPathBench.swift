// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The eagerly-built diagnostic path: RESOLVED 2026-09-07. The optimiser already removes it,
// the "instability" was this benchmark, and the change made in response has been reverted.
//
// A careful report measured `path + [.index(__r)]` per row and proposed building it inside
// the failure branches instead. The numbers in it reproduce exactly. The conclusion does
// not, and it took three wrong answers to get to that -- this header is the record.
//
// WHAT IS TRUE. Hand-rolling the emitted loop and varying ONLY where the path is built,
// 200k rows over 3 columns, with the decoded values forced live:
//
//     concrete, eager                                ~56 ns/row
//     concrete, built in the failure branch          ~13 ns/row
//     generic over the source, eager                 ~54 ns/row
//     generic over the source, in the failure branch ~14 ns/row
//
// Genericity is not the variable. In a body the optimiser cannot see through, the
// allocation costs ~42 ns/row.
//
// WHAT IS ALSO TRUE, AND SETTLES IT. The real generated `_assayBatch` runs at ~14 ns/row --
// with the eager spelling. Emitting the path in the failure branches instead produces
// **byte-identical machine code**: same 548 instructions, same five `PathComponent` buffer
// calls, `diff` of the two disassemblies is empty. At -O the compiler normalises both
// spellings to the same thing and sinks the allocation into the cold branches by itself.
// The macro change was a no-op and was reverted.
//
// WHY THE CONTROL LOOKED BISTABLE. It measured 4.18/4.20/4.66 ns/row in some builds and
// 44.6/45.3/48.0/49.0 in others, differing only by an unrelated function in this module,
// and that was blamed on specialisation being reached or not. It was this benchmark: every
// arm observed only `.count`, which leaves the optimiser free to discard the decode it does
// not need, non-deterministically. `consumeRows` reads all three fields through an
// `@inline(never)` boundary; with it, every arm is stable across runs and the control sits
// firmly with the cheap one -- 13.9/14.3/14.1 with the change, 14.6/14.3/13.6 without.
//
// `@inlinable` on `SourceDecodable.batch(from:)` was also tried, on the theory that a
// consumer could not specialise it. No reliable effect: 12-16 ns/row either way, overlapping.
// Reverted too.
//
// THE TRAP, which is the reason this file is kept. A hand-rolled reproduction needs
// `@inline(never)` or the benchmark folds it away -- and `@inline(never)` is precisely what
// stops the optimiser sinking the allocation. So the reproduction shows the full 42 ns and
// the product does not. Measuring `path + [.key(k), .index(i)]` standalone has the same
// flaw: ~49 ns/element in isolation, while deleting it outright from the JSON macro
// (emitting `at: path`, accepting wrong diagnostics, purely to measure) moved a nested array
// element from 61.89 to 60.66. On that evidence the proposed JSON redesign -- a parent
// pointer instead of a materialised `[PathComponent]`, touching `Issue`, `IssueSink` and
// every `_assay` signature -- is not justified. The 56 ns between `[Int64]` and `[JOne]` is
// object framing, key matching, a non-inlined per-element `_assay` call and struct
// construction.
//
// The general lesson, which cost the most here: a benchmark that observes only a cheap
// property of an expensive result is not measuring the result. Both the 4 ns and the 45 ns
// readings were artefacts of that, and reasoning about WHY they differed produced a
// plausible mechanism, a shipped change, and a commit message defending it -- all wrong.
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
    print("The two hand-rolled arms differ ONLY in where the row path is built. The control")
    print("is the real generated body, and it sits with the cheap arm -- see the header.")
    print(pad("variant", 44) + pad("ns/row", 10))
    print(String(repeating: "-", count: 54))
    for (label, f) in [("concrete, eager (today's shape)", pathEager),
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
