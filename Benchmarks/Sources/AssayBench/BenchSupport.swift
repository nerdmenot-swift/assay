// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// What every arm shares: the timer, the table padding, the corpus location.
//
// `measure` is minimum-of-5 rounds (docs/PERFORMANCE.md §12.4: the minimum is the least
// noisy estimator for a deterministic workload on a machine with other things running).
// These were top-level declarations in `main.swift`, which made them MainActor-isolated
// globals that every other file reached into; here they are ordinary nonisolated
// functions and constants.
//===----------------------------------------------------------------------===//

import Foundation

@inline(never)
func measure(iterations: Int, _ body: () -> Void) -> Double {
    var best = Double.infinity
    // Five rounds, keep the minimum. The minimum is the least noisy estimator for a
    // deterministic workload on a machine with other things running.
    for _ in 0..<5 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        let t1 = DispatchTime.now().uptimeNanoseconds
        best = min(best, Double(t1 - t0) / Double(iterations))
    }
    return best
}

func iterationCount(forBytes n: Int) -> Int {
    switch n {
    case ..<1_000:   return 20_000
    case ..<4_000:   return 10_000
    case ..<16_000:  return 4_000
    case ..<40_000:  return 2_000
    default:         return 1_000
    }
}


/// Where `CorpusGen` writes. `swift run -c release CorpusGen` regenerates it.
let corpusDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // AssayBench
    .deletingLastPathComponent()   // Sources
    .deletingLastPathComponent()   // Benchmarks
    .appendingPathComponent("Corpus/files")

let sizes = ["512b", "2k", "8k", "32k", "64k"]

func pad(_ s: String, _ n: Int, right: Bool = false) -> String {
    s.count >= n ? s : (right ? s + String(repeating: " ", count: n - s.count)
                              : String(repeating: " ", count: n - s.count) + s)
}

/// Boxing into a class keeps a result alive across an allocation snapshot without the
/// optimiser proving the decode dead, and costs one allocation per iteration on BOTH
/// sides — so it cancels in a ratio and shifts each absolute by exactly 1.
final class Box<T> { let v: T; init(_ v: T) { self.v = v } }
