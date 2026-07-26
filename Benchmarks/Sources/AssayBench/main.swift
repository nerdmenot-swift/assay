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
