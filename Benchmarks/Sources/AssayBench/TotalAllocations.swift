// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// TOTAL malloc traffic. Measured 2026-09-09, closing the last unqualified "unmeasured" in
// `ROADMAP.md`'s verification table.
//
// WHAT WAS MISSING, quoted so the gap is visible next to what closed it: *"The allocation gate
// counts live blocks, which misses transient allocations freed inside a decode.
// `.mallocCountTotal` would catch those and needs jemalloc, which cannot run on the musl or
// wasm legs at all — so closing this is either a bounded Darwin/Linux-only addition or a
// permanent gap, and it should be recorded as whichever it turns out to be."*
//
// **It turned out to be a bounded Darwin-only addition, and it needs no jemalloc.**
// `malloc_logger` is the global hook `MallocStackLogging` itself installs; setting it
// in-process makes the allocator call us on every allocate and every deallocate, exactly,
// with no batching. That is a strictly better instrument than the live-block gate beside it,
// which undercounts 10–15% because Darwin's nano zone reports batched statistics.
//
// WHY THIS DOES NOT REPLACE THE LIVE-BLOCK GATE. They answer different questions and the
// existing one is still the one worth gating on:
//
//   * Live blocks per decoded value asks "is the FOOTPRINT the size the design says?" — an
//     `[Int]` of 800 must be one exactly-sized allocation, a struct of short strings must be
//     zero. That is a design property with a right answer.
//   * Total traffic asks "how much work did the allocator do?" It has no a-priori right
//     answer, it moves with every stdlib version, and gating on it would fail CI for a change
//     in `String`'s growth policy. **Reported, never gated.**
//
// AND WHY THE COMPARISON IS WORTH MORE HERE THAN THERE. The live-block harness carries a
// stated limitation that it "CANNOT compare two decoders that retain the same data" — Assay
// and Foundation hold identical `String`s and `Array`s, so they hold identical blocks and the
// comparison is vacuous. Total traffic has no such problem: the retained output is the same on
// both sides and cancels, so **everything the difference shows is transient work** — the
// intermediate containers, the boxed values, the per-key machinery. That is exactly the thing
// the decode thesis is about, and it was the one thing the existing gate could not see.
//
// LIMITATIONS, stated where they are incurred:
//
//   1. Darwin only. On Linux `mallinfo2` gives bytes, not counts, and the hook does not exist;
//      the arm prints "unavailable" rather than a guess.
//   2. Not thread-safe. The hook is one global and the counters are plain integers — making
//      them atomic would put a lock on the allocator's hot path and change what is measured.
//      The harness is single-threaded here, and that is a requirement, not an accident.
//   3. It counts the *harness's* allocations too. Everything between start and stop is
//        counted, so the loop body must contain nothing but the decode — and the self-check
//        below is what establishes that the floor is where it should be.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import CHeapBytes

/// Keep a value from being optimised away without allocating anything itself — the counter
/// would see any allocation this made and attribute it to the decode.
@inline(never)
func allocSink(_ v: Int) { if v == Int.min { print("") } }

struct TotalAllocations {
    var allocations: Int
    var deallocations: Int
}

/// Count every allocation and deallocation `body` makes. Returns nil where unsupported.
func countingAllocations(_ body: () -> Void) -> TotalAllocations? {
    guard assay_total_alloc_supported() != 0 else { return nil }
    assay_total_alloc_start()
    body()
    var a = 0, d = 0
    assay_total_alloc_stop(&a, &d)
    return TotalAllocations(allocations: a, deallocations: d)
}

func runTotalAllocationBenchmarks() {
    print("")
    print("Total malloc traffic — first measured 2026-09-09")
    print("The live-block gate cannot see an allocation that is freed inside the decode.")
    print("This can. Darwin only, via malloc_logger; REPORTED, never gated — total traffic")
    print("has no a-priori right answer and moves with every stdlib version.")
    print("")

    guard assay_total_alloc_supported() != 0 else {
        print("  unavailable on this platform — no exact allocation counter exists here,")
        print("  and a guessed number is worse than none. ROADMAP records it as open.")
        return
    }

    // THE SELF-CHECK, and the arm refuses to report without it. Same discipline as the
    // live-block harness: measure something whose count is arithmetic before trusting the
    // instrument on something whose count is the question.
    let probe = countingAllocations {
        var keep: [[Int]] = []
        for i in 0..<100 { keep.append(Array(repeating: i, count: 64)) }
        allocSink(keep.count)
    }
    guard let p = probe, p.allocations >= 100, p.allocations <= 260 else {
        print("  SELF-CHECK FAILED — 100 exactly-sized arrays counted "
              + "\(probe?.allocations ?? -1) allocations, expected 100 plus the array's own")
        print("  growth. Not reporting a number from an instrument that cannot count.")
        return
    }
    print("self-check: 100 exactly-sized [Int] allocations counted as "
          + "\(p.allocations) allocs / \(p.deallocations) frees — instrument trusted")
    print("")

    let corpusItem = #"""
        {"id":"item-0","name":"a name of ordinary length","description":\
        "a description of moderate length for this item","created_at":\
        "2026-08-09T12:00:00Z","amount":12.5,"active":true,"retry_count":2,\
        "owner_id":"owner-0"}
        """#.replacingOccurrences(of: "\\\n", with: "")

    print(pad("shape", 16, right: true) + pad("Foundation", 12) + pad("Assay", 10)
          + pad("ratio", 9) + pad("transient", 11))
    print(String(repeating: "-", count: 58))

    for count in [1, 10, 50] {
        var text = #"{"request_id":"r","generated_at":"t","page":1,"total_count":\#(count),"#
        text += #""has_more":false,"items":["#
        for i in 0..<count {
            if i > 0 { text += "," }
            text += corpusItem
        }
        text += "]}"
        let bytes = Array(text.utf8)
        let data = Data(bytes)
        let decoder = JSONDecoder()

        guard (try? AllocPayload.parse(json: bytes)) != nil,
              (try? decoder.decode(CodableAllocPayload.self, from: data)) != nil else {
            print(pad("\(count) items", 16, right: true) + "  SKIPPED — a decoder failed")
            continue
        }

        // One decode each, with the result released inside the measured region. Freeing it
        // inside is deliberate: `deallocations` then covers the retained output too, so
        // `allocations - deallocations` is near zero and the ALLOCATION count is the whole
        // story — retained plus transient, which is what "total traffic" means.
        guard let mine = countingAllocations({
                  allocSink((try? AllocPayload.parse(json: bytes))?.items.count ?? 0)
              }),
              let theirs = countingAllocations({
                  allocSink((try? decoder.decode(CodableAllocPayload.self, from: data))?
                              .items.count ?? 0)
              }) else { continue }

        // The retained output is identical on both sides and cancels; what is left is
        // transient. Reported as a count rather than a share, because attributing it
        // precisely would need the stack frames this hook is deliberately not collecting.
        let transient = theirs.allocations - mine.allocations
        print(pad("\(count) items", 16, right: true)
              + pad("\(theirs.allocations)", 12)
              + pad("\(mine.allocations)", 10)
              + pad(String(format: "%.2fx", Double(theirs.allocations)
                                            / Double(max(1, mine.allocations))), 9)
              + pad("\(transient)", 11))
    }

    print("")
    print("The last column is Foundation's allocation count minus Assay's. Both decoders")
    print("retain the same Strings and Arrays, so the retained part cancels exactly and the")
    print("difference is work that was allocated and freed inside the decode — which is the")
    print("one thing the live-block gate structurally cannot see.")
}

@Schema(keys: .snakeCase)
struct AllocItem {
    var id: String
    var name: String
    var description: String
    var createdAt: String
    var amount: Double
    var active: Bool
    var retryCount: Int
    var ownerId: String
}

@Schema(keys: .snakeCase)
struct AllocPayload {
    var requestId: String
    var generatedAt: String
    var page: Int
    var totalCount: Int
    var hasMore: Bool
    var items: [AllocItem]
}

struct CodableAllocItem: Decodable {
    var id: String
    var name: String
    var description: String
    var createdAt: String
    var amount: Double
    var active: Bool
    var retryCount: Int
    var ownerId: String
    enum CodingKeys: String, CodingKey {
        case id, name, description, amount, active
        case createdAt = "created_at"
        case retryCount = "retry_count"
        case ownerId = "owner_id"
    }
}

struct CodableAllocPayload: Decodable {
    var requestId: String
    var generatedAt: String
    var page: Int
    var totalCount: Int
    var hasMore: Bool
    var items: [CodableAllocItem]
    enum CodingKeys: String, CodingKey {
        case page, items
        case requestId = "request_id"
        case generatedAt = "generated_at"
        case totalCount = "total_count"
        case hasMore = "has_more"
    }
}
