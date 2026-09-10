// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The generated columnar body against a hand-written floor. Added 2026-09-10, the day
// a slow re-read of the columnar path found it 5x off that floor.
//
// WHAT WAS WRONG. The generated row loop opened with `let path = path + [.index(__r)]` —
// one array allocation per row for a diagnostic path a clean batch never reads. A report
// (haul's, 2026-09-01) measured exactly that and proposed moving the line; the change was
// made, then REVERTED on 2026-09-07 with a header claiming the optimiser sank the
// allocation on its own and the real body ran at ~14 ns/row. On the tree of 2026-09-10 the
// real body measured 52.6 ns/row against 9.6 for the same semantics hand-written — the
// eager arm's number, not the lazy one's. Whatever that earlier measurement saw, it was
// not the shipped body's steady state. DiagnosticPathBench.swift keeps the fuller record.
//
// WHAT CHANGED. There is no per-row path at all now. The loop writes two integers into
// the sink (`_enterRow`), and `IssueSink.add` — cold — inserts the row index into any
// issue or warning recorded during that row. Same diagnostics, pinned by the same tests.
//
// WHY THIS ARM STAYS. It is the only measurement that would catch the regression: the
// allocation gate counts LIVE blocks and a per-row array freed within the row never shows
// there. Four rows, in order: what a loop with no presence machinery costs; the same
// semantics hand-written with per-column facts hoisted; the generated body called
// concretely; the generated body through the protocol extension a driver would use. The
// last two should sit within ~15% of the first.
//===----------------------------------------------------------------------===//

import Foundation
import Assay

@inline(never)
func consumeBench(_ rows: [BenchRow]) -> Int {
    var acc = 0
    for r in rows {
        acc &+= r.id ^ r.age ^ Int(r.score) ^ (r.active ? 1 : 0) ^ r.name.utf8.count
            ^ r.email.utf8.count ^ r.createdAt.utf8.count ^ r.ownerId.utf8.count
    }
    return acc
}

/// The floor: direct indexing, no presence machinery at all.
@inline(never)
func floorBatch(_ s: borrowing BenchColumnStore) -> [BenchRow] {
    var out: [BenchRow] = []
    out.reserveCapacity(s.rowCount)
    let ids = s.ids, names = s.names, emails = s.emails, ages = s.ages
    let scores = s.scores, actives = s.actives, createds = s.createds, owners = s.owners
    for r in 0..<s.rowCount {
        out.append(BenchRow(id: Int(truncatingIfNeeded: ids[r]), name: names[r], email: emails[r],
                            age: Int(truncatingIfNeeded: ages[r]), score: scores[r],
                            active: actives[r], createdAt: createds[r], ownerId: owners[r]))
    }
    return out
}

/// The generated body's semantics — presence, nulls, exact conversion — hand-written with
/// every per-column fact hoisted out of the row loop.
@inline(never)
func hoistedBatch<C: ColumnarSource & ~Copyable>(
    _ s: borrowing C, _ sink: inout IssueSink, _ path: [PathComponent]
) -> [BenchRow] {
    let n = s.rowCount
    guard let c0 = s.int64Column("id", 0), c0.count >= n,
          let c1 = s.stringColumn("name", 1), c1.count >= n,
          let c2 = s.stringColumn("email", 2), c2.count >= n,
          let c3 = s.int64Column("age", 3), c3.count >= n,
          let c4 = s.doubleColumn("score", 4), c4.count >= n,
          let c5 = s.boolColumn("active", 5), c5.count >= n,
          let c6 = s.stringColumn("created_at", 6), c6.count >= n,
          let c7 = s.stringColumn("owner_id", 7), c7.count >= n else { return [] }
    let n0 = s.nulls("id", 0), n1 = s.nulls("name", 1), n2 = s.nulls("email", 2)
    let n3 = s.nulls("age", 3), n4 = s.nulls("score", 4), n5 = s.nulls("active", 5)
    let n6 = s.nulls("created_at", 6), n7 = s.nulls("owner_id", 7)
    var out: [BenchRow] = []
    out.reserveCapacity(n)
    for r in 0..<n {
        if _assayIsNullAt(n0, r) || _assayIsNullAt(n1, r) || _assayIsNullAt(n2, r)
            || _assayIsNullAt(n3, r) || _assayIsNullAt(n4, r) || _assayIsNullAt(n5, r)
            || _assayIsNullAt(n6, r) || _assayIsNullAt(n7, r) {
            _assayRowMissing(&sink, path + [.index(r)], "id"); continue
        }
        guard let id = Int(exactly: c0[r]), let age = Int(exactly: c3[r]) else {
            _assayRowMissing(&sink, path + [.index(r)], "id"); continue
        }
        out.append(BenchRow(id: id, name: c1[r], email: c2[r], age: age, score: c4[r],
                            active: c5[r], createdAt: c6[r], ownerId: c7[r]))
    }
    return out
}

func runColumnarFloor() {
    let n = 200_000
    let store = makeStore(rows: n)
    print("")
    print("Columnar: the generated body against a hand-written floor")
    print("200k rows, 8 columns, 4 of them String. Values are consumed after every arm;")
    print("a benchmark that reads only `.count` of this result measures nothing.")
    print(pad("variant", 44) + pad("ns/row", 10))
    print(String(repeating: "-", count: 54))
    let arms: [(String, () -> [BenchRow])] = [
        ("floor: direct indexing, no checks", { floorBatch(store) }),
        ("hoisted: same semantics, hand-written", { var s = IssueSink(); return hoistedBatch(store, &s, []) }),
        ("generated _assayBatch, called concretely", { var s = IssueSink(); return BenchRow._assayBatch(from: store, into: &s, at: []) }),
        ("generated, via batch(from:) [protocol ext]", { BenchRow.batch(from: store).values }),
    ]
    for (label, f) in arms {
        var best = Double.infinity
        for _ in 0..<5 {
            let ns = measure(iterations: 1) { precondition(consumeBench(f()) != Int.min) }
            best = min(best, ns)
        }
        print(pad(label, 44) + pad(String(format: "%.1f", best / Double(n)), 10))
    }
}
