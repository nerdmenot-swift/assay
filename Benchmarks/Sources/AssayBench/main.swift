// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The falsification check. docs/PERFORMANCE.md §14, phase 1:
//
//   "Benchmark against Foundation on the corpus of §12.2 and count allocations. If this
//    does not comfortably clear ZippyJSON's 1.38x, the thesis is wrong and everything
//    below is moot."
//
// ZippyJSON bolted simdjson onto Codable and got 1.38x average over Foundation, 1.04x on
// the most API-shaped payload in its own set. Assay's claim is that the parser was never
// the bottleneck — the container boundary was — so a *scalar* Swift decoder with no SIMD
// at all should clear that number comfortably. If it does not, there is nothing to
// salvage by adding vectors.
//
// Methodology, and its limits, stated up front because a table without them is worthless:
//   * ns/op and allocs/op, never GB/s. At 1-50 kB fixed per-call overhead is a large
//     fraction of total cost, so throughput flatters or damns arbitrarily by size.
//   * Both decoders are hoisted out of the loop (warm). Real servers decode the same type
//     thousands of times. A cold-only benchmark understates Assay; a warm-only one
//     overstates it for CLI users. Warm is reported here and labelled as such.
//   * -O, never -Ounchecked. Comparing an -Ounchecked subject against a -O baseline is on
//     the list of things that make a README table worthless.
//   * Foundation's JSONDecoder is fully general and Codable-driven; Assay's macro knows
//     the schema at compile time. That is a real advantage AND an unfair comparison
//     unless said out loud. Saying it out loud.
//===----------------------------------------------------------------------===//

import Foundation
import Assay

// MARK: - The shared model, declared twice

@Schema(keys: .snakeCase)
struct Item {
    var id: String
    var sequence: Int
    var name: String
    var description: String
    var createdAt: String
    var updatedAt: String
    var amount: Double
    var active: Bool
    var retryCount: Int
    var ownerId: String
}

@Schema(keys: .snakeCase)
struct Payload {
    var requestId: String
    var generatedAt: String
    var page: Int
    var totalCount: Int
    var hasMore: Bool
    var items: [Item]
}

struct CodableItem: Codable {
    var id: String
    var sequence: Int
    var name: String
    var description: String
    var created_at: String
    var updated_at: String
    var amount: Double
    var active: Bool
    var retry_count: Int
    var owner_id: String
}

// Float-dense, canada.json-shaped. The case a scalar decoder with no Eisel-Lemire is
// expected to lose — measured so the loss can be published rather than assumed.
@Schema
struct Polygon {
    var type: String
    var coordinates: [[Double]]
}

struct CodablePolygon: Codable {
    var type: String
    var coordinates: [[Double]]
}

struct CodablePayload: Codable {
    var request_id: String
    var generated_at: String
    var page: Int
    var total_count: Int
    var has_more: Bool
    var items: [CodableItem]
}

// MARK: - Timing

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

// MARK: - Driver

let corpusDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // AssayBench
    .deletingLastPathComponent()   // Sources
    .deletingLastPathComponent()   // Benchmarks
    .appendingPathComponent("Corpus/files")

let sizes = ["512b", "2k", "8k", "32k", "64k"]

print("Assay phase-1 falsification check")
print("Toolchain: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("Warm (decoder hoisted). Minimum of 5 rounds. -O. Scalar Swift, no SIMD, no C.")
print("")
func pad(_ s: String, _ n: Int, right: Bool = false) -> String {
    s.count >= n ? s : (right ? s + String(repeating: " ", count: n - s.count)
                              : String(repeating: " ", count: n - s.count) + s)
}
print(pad("size", 10, right: true) + pad("bytes", 10) + pad("Foundation ns", 15)
      + pad("Assay ns", 13) + pad("ratio", 10))
print(String(repeating: "-", count: 62))

var ratios: [Double] = []

for size in sizes {
    let url = corpusDir.appendingPathComponent("apimodel-\(size).json")
    guard let data = try? Data(contentsOf: url) else {
        print("missing \(url.lastPathComponent) — run: swift run -c release CorpusGen")
        continue
    }
    let bytes = [UInt8](data)
    let iters = iterationCount(forBytes: bytes.count)

    // Correctness gate before timing: a fast wrong answer is not a result.
    let decoder = JSONDecoder()
    guard let ref = try? decoder.decode(CodablePayload.self, from: data) else {
        print("Foundation failed to decode \(size)"); continue
    }
    let mine = Payload.diagnose(json: bytes)
    guard let got = mine.value else {
        print("Assay failed to decode \(size): \(mine.issues.prefix(3))"); continue
    }
    precondition(got.items.count == ref.items.count, "item count mismatch at \(size)")
    precondition(got.requestId == ref.request_id, "field mismatch at \(size)")
    precondition(got.items.first?.id == ref.items.first?.id, "nested mismatch at \(size)")

    let fNs = measure(iterations: iters) {
        _ = try? decoder.decode(CodablePayload.self, from: data)
    }
    let aNs = measure(iterations: iters) {
        _ = Payload.diagnose(json: bytes).value
    }

    let ratio = fNs / aNs
    ratios.append(ratio)
    print(pad(size, 10, right: true)
          + pad("\(bytes.count)", 10)
          + pad(String(format: "%.0f", fNs), 15)
          + pad(String(format: "%.0f", aNs), 13)
          + pad(String(format: "%.2fx", ratio), 10))
}

guard !ratios.isEmpty else {
    print("no corpus files decoded — nothing measured")
    exit(1)
}
// ---- float-dense arm ----
print("")
print("float-dense (canada.json-shaped coordinate pairs)")
print(pad("size", 10, right: true) + pad("bytes", 10) + pad("Foundation ns", 15)
      + pad("Assay ns", 13) + pad("ratio", 10))
print(String(repeating: "-", count: 62))

var floatRatios: [Double] = []
for size in sizes {
    let url = corpusDir.appendingPathComponent("floats-dense-\(size).json")
    guard let data = try? Data(contentsOf: url) else { continue }
    let bytes = [UInt8](data)
    let iters = iterationCount(forBytes: bytes.count)
    let dec = JSONDecoder()
    guard let ref = try? dec.decode(CodablePolygon.self, from: data) else { continue }
    let mine = Polygon.diagnose(json: bytes)
    guard let got = mine.value else {
        print("Assay failed on floats-dense-\(size): \(mine.issues.prefix(2))"); continue
    }
    precondition(got.coordinates.count == ref.coordinates.count)
    // Bit-exactness against Foundation, not approximate equality. A fast wrong float is
    // not a result.
    for (a, b) in zip(got.coordinates, ref.coordinates) {
        for (x, y) in zip(a, b) {
            precondition(x.bitPattern == y.bitPattern,
                         "float mismatch at floats-dense-\(size): \(x) vs \(y)")
        }
    }
    let fNs = measure(iterations: iters) { _ = try? dec.decode(CodablePolygon.self, from: data) }
    let aNs = measure(iterations: iters) { _ = Polygon.diagnose(json: bytes).value }
    floatRatios.append(fNs / aNs)
    print(pad(size, 10, right: true) + pad("\(bytes.count)", 10)
          + pad(String(format: "%.0f", fNs), 15)
          + pad(String(format: "%.0f", aNs), 13)
          + pad(String(format: "%.2fx", fNs / aNs), 10))
}
if !floatRatios.isEmpty {
    print(String(format: "mean on float-dense: %.2fx",
                 floatRatios.reduce(0, +) / Double(floatRatios.count)))
}
print("")

let mean = ratios.reduce(0, +) / Double(ratios.count)
print("")
print(String(format: "mean speedup vs Foundation: %.2fx", mean))
print("ZippyJSON's published average (simdjson + Codable): 1.38x")
print(mean > 1.38
      ? "PASS — clears the falsification condition."
      : "FAIL — thesis not supported; SIMD/C work is moot per PERFORMANCE.md §14.")

//===----------------------------------------------------------------------===//
// The full corpus sweep, the allocation gate, and the negative path. Everything above
// this line answers the falsification condition; everything below answers "and what
// about the other 79 files".
//===----------------------------------------------------------------------===//

func sweep(_ title: String, _ note: String, _ shapes: [ShapeRunner]) -> [Double] {
    print("")
    print(title)
    print(note)
    print(pad("shape", 20, right: true) + pad("size", 7) + pad("bytes", 9)
          + pad("Foundation ns", 15) + pad("Assay ns", 12) + pad("ratio", 9))
    print(String(repeating: "-", count: 72))

    var collected: [Double] = []
    for shape in shapes {
        for size in sizes {
            let url = corpusDir.appendingPathComponent("\(shape.name)-\(size).json")
            guard let data = try? Data(contentsOf: url) else { continue }
            let bytes = [UInt8](data)

            // Correctness gate: both sides must produce a value, or the row is a lie.
            guard shape.foundation(data) else {
                print(pad(shape.name, 20, right: true) + pad(size, 7)
                      + "   Foundation declined this file"); continue
            }
            guard shape.assay(bytes) else {
                print(pad(shape.name, 20, right: true) + pad(size, 7)
                      + "   Assay declined this file"); continue
            }

            let iters = iterationCount(forBytes: bytes.count)
            let fNs = measure(iterations: iters) { _ = shape.foundation(data) }
            let aNs = measure(iterations: iters) { _ = shape.assay(bytes) }
            let ratio = fNs / aNs
            collected.append(ratio)
            print(pad(shape.name, 20, right: true) + pad(size, 7)
                  + pad("\(bytes.count)", 9)
                  + pad(String(format: "%.0f", fNs), 15)
                  + pad(String(format: "%.0f", aNs), 12)
                  + pad(String(format: "%.2fx", ratio), 9))
        }
    }
    if !collected.isEmpty {
        let m = collected.reduce(0, +) / Double(collected.count)
        let lo = collected.min()!, hi = collected.max()!
        print(String(format: "mean %.2fx over %d files (min %.2fx, max %.2fx)",
                     m, collected.count, lo, hi))
    }
    return collected
}

let structRatios = sweep(
    "Struct decode — shapes a fixed struct consumes entirely",
    "@Schema vs Codable. This is the headline claim.",
    structShapes)

let prefixRatios = sweep(
    "Prefix decode + unknown-key skip — flat shapes",
    "These scale by ADDING KEYS (bigints-64k has 2232), so a 6-field struct decodes a"
    + "\nprefix and skips the rest. Both decoders do the same work; the skip path is the"
    + "\npoint. This is the most common real shape: a client struct, a verbose response.",
    prefixShapes)

// ---- Generic value model, every positive file ----
print("")
print("Generic value model — JSON.Value vs JSONSerialization, all positive corpus files")
print("No struct, no macro, no key dispatch: Assay without its structural advantage.")

var valueRatios: [Double] = []
var valueFiles = 0
if let all = try? FileManager.default.contentsOfDirectory(
    at: corpusDir, includingPropertiesForKeys: nil) {
    for url in all.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix("neg-") {
        guard let data = try? Data(contentsOf: url) else { continue }
        let bytes = [UInt8](data)
        guard (try? JSON.Value.parse(bytes)) != nil,
              (try? JSONSerialization.jsonObject(with: data)) != nil else { continue }
        let iters = max(200, iterationCount(forBytes: bytes.count) / 4)
        let fNs = measure(iterations: iters) {
            _ = try? JSONSerialization.jsonObject(with: data)
        }
        let aNs = measure(iterations: iters) { _ = try? JSON.Value.parse(bytes) }
        valueRatios.append(fNs / aNs)
        valueFiles += 1
    }
}
if !valueRatios.isEmpty {
    let m = valueRatios.reduce(0, +) / Double(valueRatios.count)
    print(String(format: "mean %.2fx over %d files (min %.2fx, max %.2fx)",
                 m, valueFiles, valueRatios.min()!, valueRatios.max()!))
    print("A value model has no Codable boundary to delete, so this is the honest floor:")
    print("what Assay's scanner is worth on its own, separate from the macro's advantage.")
}

// ---- Negative path ----
print("")
print("Negative path — cost of collecting every error vs Foundation's throw-on-first")
print(pad("file", 30, right: true) + pad("Foundation ns", 15) + pad("Assay ns", 12)
      + pad("issues", 8))
print(String(repeating: "-", count: 65))

for name in ["neg-invalid-early", "neg-invalid-late", "neg-truncated",
             "neg-type-mismatch", "neg-validation-fail-many", "neg-deep-nesting"] {
    let url = corpusDir.appendingPathComponent("\(name).json")
    guard let data = try? Data(contentsOf: url) else { continue }
    let bytes = [UInt8](data)
    let iters = max(500, iterationCount(forBytes: bytes.count) / 8)
    let dec = JSONDecoder()
    let fNs = measure(iterations: iters) {
        _ = try? dec.decode(CodablePayload.self, from: data)
    }
    let d = Payload.diagnose(json: bytes)
    let aNs = measure(iterations: iters) { _ = Payload.diagnose(json: bytes) }
    print(pad(name, 30, right: true)
          + pad(String(format: "%.0f", fNs), 15)
          + pad(String(format: "%.0f", aNs), 12)
          + pad("\(d.issues.count)", 8))
}
print("Foundation throws on the first problem and stops; Assay walks the whole document")
print("and reports every one. A slower number here is the feature, not a regression.")

// ---- Allocation gate ----
// Boxing into a class keeps results alive across the snapshot without the optimiser
// proving the decode dead, and costs one allocation per iteration on BOTH sides — so it
// cancels in the ratio and shifts each absolute by exactly 1.
final class Box<T> { let v: T; init(_ v: T) { self.v = v } }

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

// Top-level state is MainActor-isolated; a box keeps the reporting helper callable.
final class AllocFailures: @unchecked Sendable {
    static let shared = AllocFailures()
    var messages: [String] = []
}

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
        AllocFailures.shared.messages.append(
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
if AllocFailures.shared.messages.isEmpty {
    print("allocation gate: PASS")
} else {
    print("allocation gate: FAIL")
    for f in AllocFailures.shared.messages { print("  \(f)") }
}

// ---- YAML and XML ----
runFormatBenchmarks(corpusDir: corpusDir, sizes: sizes)

// ---- Dates ----
runDateBenchmarks(corpusDir: corpusDir, sizes: sizes)

// ---- Dictionaries ----
runDictionaryBenchmarks(corpusDir: corpusDir, sizes: sizes)

print("")
print("Summary")
print(String(repeating: "=", count: 40))
func summarise(_ label: String, _ rs: [Double]) {
    guard !rs.isEmpty else { return }
    print(String(format: "%@: %.2fx mean over %d files",
                 label, rs.reduce(0, +) / Double(rs.count), rs.count))
}
summarise("struct decode      ", structRatios)
summarise("prefix + skip      ", prefixRatios)
summarise("generic value model", valueRatios)
print("")
print("Every ratio above is this machine, this toolchain, warm, minimum of 5 rounds.")
print("None of them is a claim about another platform — see CLAUDE.md's honesty rules.")

if !AllocFailures.shared.messages.isEmpty { exit(1) }
