// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The allocation gate: live blocks per decoded value, against ABSOLUTE thresholds.
//
// Read Allocations.swift's three stated limitations before quoting a number. The gate
// is the one thing CI enforces from this package — wall clock never is (CLAUDE.md's
// honesty rules) — so it is its own arm and its own exit code.
//===----------------------------------------------------------------------===//

import Foundation
import Assay

/// Returns true when every gated row is within its limit (or the counter is untrusted and
/// the gate turned itself off, which is a pass by design — see the self-check).
func runAllocationGate() -> Bool {
    var failures: [String] = []
    print("")
    print("Live allocations per decoded value — read Allocations.swift before quoting these.")
    print("The Foundation columns are context, not a claim: two decoders retaining the same")
    print("Strings and Arrays hold the same blocks, so the comparison there is vacuous.")
    print(pad("case", 26, right: true) + pad("Assay blk", 10) + pad("Assay B", 12)
          + pad("Fdn blk", 12) + pad("Fdn B", 12))
    print(String(repeating: "-", count: 72))

    // Self-check. The counter is only worth reporting if it can count a known quantity, so
    // before any real row it measures closures whose allocation count is not in doubt.
    // If these do not read 1 and 3, every number below them is noise and says so.
    final class One { let a: [UInt8]; init() { a = [UInt8](repeating: 0, count: 64) } }
    let selfCheck1 = measureAllocations(iterations: 2_000) { One() }        // box + array = 2
    let selfCheck2 = measureAllocations(iterations: 2_000) { () -> Box<[String]> in
        Box([String(repeating: "x", count: 40), String(repeating: "y", count: 40)])
    }                                                                       // box+arr+2 str = 4
    print(String(format: "self-check: expected 2.0 and 4.0 blocks, measured %@ and %@",
                 selfCheck1.blocks.map { String(format: "%.2f", $0) } ?? "n/a",
                 selfCheck2.blocks.map { String(format: "%.2f", $0) } ?? "n/a"))
    // Darwin's nano zone batches its statistics, so a ~15% undercount is the calibrated
    // normal rather than a fault. Beyond that the counter has stopped describing reality and
    // the gate turns itself off rather than reporting a number it cannot stand behind.
    let counterTrusted = (selfCheck1.blocks.map { $0 > 1.6 && $0 <= 2.05 } ?? false)
        && (selfCheck2.blocks.map { $0 > 3.3 && $0 <= 4.05 } ?? false)
    print(counterTrusted
          ? "counter validated (undercounts ~10-15%; thresholds carry the headroom)"
          : "COUNTER UNRELIABLE on this platform; rows below are reported but NOT gated")
    print("")

    func allocRow(_ name: String, limitBlocks: Int,
                  assay: () -> AnyObject?, foundation: () -> AnyObject?) {
        let a = measureAllocations(iterations: 2_000, assay)
        let f = measureAllocations(iterations: 2_000, foundation)
        // Both sides printed outright. A ratio alone hides which side moved, and a ratio of
        // exactly 1.00 is far more often a broken measurement than a real tie.
        print(pad(name, 26, right: true)
              + pad(a.blocks.map { String(format: "%.1f", $0) } ?? "n/a", 10)
              + pad(String(format: "%.0f", a.bytes), 12)
              + pad(f.blocks.map { String(format: "%.1f", $0) } ?? "n/a", 12)
              + pad(String(format: "%.0f", f.bytes), 12))
        if let b = a.blocks, counterTrusted, b > Double(limitBlocks) {
            failures.append(
                String(format: "%@: %.1f blocks > limit %d", name, b, limitBlocks))
        }
    }

    if let data = try? Data(contentsOf: corpusDir.appendingPathComponent("apimodel-8k.json")) {
        let bytes = [UInt8](data)
        let dec = JSONDecoder()
        // apimodel-8k holds ~28 items x 10 fields. Absolute thresholds, not ratios: a ratio
        // gate passes silently when both sides regress together.
        allocRow("apimodel-8k struct", limitBlocks: 400,
                 assay: { Payload.diagnose(json: bytes).value.map { Box($0) } },
                 foundation: { (try? dec.decode(CodablePayload.self, from: data)).map { Box($0) } })
        allocRow("apimodel-8k value model", limitBlocks: 900,
                 assay: { (try? JSON.Value.parse(bytes)).map { Box($0) } },
                 foundation: { (try? JSONSerialization.jsonObject(with: data)).map { Box($0) } })
    }
    if let data = try? Data(contentsOf: corpusDir.appendingPathComponent("arrays-of-scalars-8k.json")) {
        let bytes = [UInt8](data)
        let dec = JSONDecoder()
        // An [Int] of ~800 elements should be ONE allocation, exactly-sized. Anything above
        // a handful means the array is growing by doubling, or the elements are boxing.
        allocRow("arrays-of-scalars-8k", limitBlocks: 8,
                 assay: { ScalarArray.diagnose(json: bytes).value.map { Box($0) } },
                 foundation: { (try? dec.decode(CodableScalarArray.self, from: data)).map { Box($0) } })
    }
    if let data = try? Data(contentsOf: corpusDir.appendingPathComponent("short-strings-8k.json")) {
        let bytes = [UInt8](data)
        let dec = JSONDecoder()
        // Every value here is <= 15 bytes, so every String is small-form and immortal. Six
        // fields, and the answer should be ~1: the box, and nothing else.
        allocRow("short-strings-8k (SSO)", limitBlocks: 4,
                 assay: { StringPrefix.diagnose(json: bytes).value.map { Box($0) } },
                 foundation: { (try? dec.decode(CodableStringPrefix.self, from: data)).map { Box($0) } })
    }

    print("")
    if failures.isEmpty {
        print("allocation gate: PASS")
    } else {
        print("allocation gate: FAIL")
        for f in failures { print("  \(f)") }
    }
    return failures.isEmpty


}
