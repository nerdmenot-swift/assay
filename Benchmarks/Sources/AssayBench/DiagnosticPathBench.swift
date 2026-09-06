// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The eagerly-built diagnostic path: a real 12x cliff that the optimiser USUALLY hides.
// Measured 2026-09-06.
//
// THE MECHANISM IS REAL AND LARGE. Generated code built `path + [.index(__r)]` once per row
// -- an Array allocation for a value a clean batch never reads, since only
// `_assayRowMissing` and the rule engine look at it. Hand-rolling the emitted loop and
// varying ONLY where the path is built, at 200k rows over 3 columns:
//
//     concrete, eager (the old shape)                ~45 ns/row
//     concrete, built in the failure branch           ~3.7 ns/row
//     generic over the source, eager                 ~44 ns/row
//     generic over the source, in the failure branch  ~3.6 ns/row
//
// Genericity is not the variable; where the path is built is. Twelve times.
//
// WHAT COULD NOT BE ESTABLISHED, AND IT MATTERS. The control -- the REAL generated
// `_assayBatch` -- refused to give a stable answer. Across rebuilds of this package that
// differed only by an unrelated function being present in this module, the same generated
// body measured 4.18, 4.20, 4.66 ns/row in some builds and 44.6, 45.3, 48.0, 49.0 in
// others. That swing appeared both WITH the path moved into the failure branches and
// without it, so it is not the fix moving and it is not the call shape: `batch(from:)` is a
// protocol extension generic over Self, and whether `_assayBatch` gets specialised into the
// caller -- and with it whether the dead allocation gets sunk -- is decided by inlining
// pressure elsewhere in the module.
//
// So there is no honest end-to-end A/B here, and this file does not claim one.
//
// WHY THE FIX SHIPPED ANYWAY. The two facts above are enough on their own: when the
// optimiser sinks the allocation the fix costs nothing, and when it does not the fix saves
// 12x. It removes a cliff whose trigger is outside the schema author's control and not
// visible in their code. That is a better reason than a benchmark delta would have been.
//
// A NOTE ON REPRODUCTIONS. A hand-rolled copy needs `@inline(never)` or the benchmark folds
// it away, and `@inline(never)` is exactly what stops the optimiser sinking the allocation.
// So the reproduction always shows the full 45 ns and the real body often does not. Both
// numbers are correct; they answer different questions. The same trap applies to measuring
// `path + [.key(k), .index(i)]` standalone -- it reads ~49 ns/element in isolation, and
// deleting it outright from the JSON macro (emitting `at: path`, accepting wrong
// diagnostics, purely to measure) moved a nested array element from 61.89 to 60.66. On the
// strength of that, the proposed redesign of the JSON path -- a parent pointer instead of a
// materialised `[PathComponent]`, touching `Issue`, `IssueSink` and every `_assay`
// signature -- is NOT justified. The 56 ns between `[Int64]` and `[JOne]` is object
// framing, key matching, a non-inlined per-element `_assay` call and struct construction.
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
            precondition(f(store, &sink, []).count == n)
        }
        print(pad(label, 44) + pad(String(format: "%.2f", ns / Double(n)), 10))
    }
    // The real body is GENERIC over the source, which is the shape that matters.
    let ge = measure(iterations: 1) {
        var sink = IssueSink(limits: .default)
        precondition(pathEagerG(store, &sink, []).count == n)
    }
    print(pad("generic, eager (the real body's shape)", 44)
          + pad(String(format: "%.2f", ge / Double(n)), 10))
    let gl = measure(iterations: 1) {
        var sink = IssueSink(limits: .default)
        precondition(pathLazyG(store, &sink, []).count == n)
    }
    print(pad("generic, in the failure branch", 44)
          + pad(String(format: "%.2f", gl / Double(n)), 10))
    let real = measure(iterations: 1) {
        precondition(PRow.batch(from: store).values.count == n)
    }
    print(pad("real, via batch(from:) [protocol ext]", 44)
          + pad(String(format: "%.2f", real / Double(n)), 10))
    // Same body, called directly on the concrete type — no witness table in the way.
    let direct = measure(iterations: 1) {
        var sink = IssueSink(limits: .default)
        precondition(PRow._assayBatch(from: store, into: &sink, at: []).count == n)
    }
    print(pad("real _assayBatch, called concretely", 44)
          + pad(String(format: "%.2f", direct / Double(n)), 10))
}
