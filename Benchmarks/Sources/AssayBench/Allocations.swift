// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Allocation counting, without a dependency.
//
// CLAUDE.md's honesty rules require gating CI on allocation counts rather than wall
// clock, and name package-benchmark's `.mallocCountTotal`. That metric needs jemalloc
// installed alongside the toolchain, and it cannot run on the musl or wasm legs of the
// matrix at all — so the gate would be Darwin-and-Linux-with-a-brew-install only, which
// is most of the cost of writing it here and none of the control.
//
// What this measures instead is LIVE allocations per decoded value: snapshot the
// allocator, decode N documents and keep every result alive, snapshot again. The delta
// divided by N is how many heap blocks one decoded value is holding — every String that
// exceeded SSO, every Array, every Dictionary.
//
// THREE LIMITATIONS, all of them load-bearing, none of them hidden:
//
//   1. It is not total malloc traffic. Transient allocations made and freed inside the
//      decode never appear. `.mallocCountTotal` would catch those; this does not.
//
//   2. It undercounts by roughly 10-15% on Darwin. The self-check in main.swift measures
//      closures whose block count is arithmetic — and reads 1.73 where the answer is 2.
//      Darwin's nano zone (allocations <= 256 bytes) reports batched statistics rather
//      than exact live counts. Thresholds carry headroom for this; the self-check runs
//      before every gated row and disables the gate outright if the error grows.
//
//   3. It CANNOT compare two decoders that retain the same data. Assay's Payload and
//      Foundation's CodablePayload hold identical Strings and Arrays, so they hold
//      identical numbers of blocks — the measurement is correct and the comparison is
//      vacuous. The Foundation column exists as context, never as a claim.
//
// What survives all three is the question worth gating on: is the live footprint of one
// decoded value the size the design says it should be? An [Int] of 800 elements must be
// ONE exactly-sized allocation, not a doubling sequence. A six-field struct of <= 15-byte
// strings must be ZERO, because every one of those Strings is small-form and immortal.
// A Dictionary appearing in the per-object path would show up immediately. That is the
// regression this exists to catch, and on those questions it is unambiguous.
//
// Darwin: malloc_zone_statistics over every registered zone gives a live block count.
// Linux: mallinfo2 gives bytes in use but no block count, so the count is reported as
// unavailable rather than guessed. Never report a number the platform did not supply.
//===----------------------------------------------------------------------===//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
// `mallinfo2` is declared in malloc.h, which the Glibc module does not re-export, so it is
// invisible to `import Glibc` alone. Declaring the shape here is the portable way to reach
// it — only `uordblks` is read, and only for a bytes figure the gate never asserts on.
private struct CMallinfo2 {
    var arena: Int = 0, ordblks: Int = 0, smblks: Int = 0, hblks: Int = 0
    var hblkhd: Int = 0, usmblks: Int = 0, fsmblks: Int = 0, uordblks: Int = 0
    var fordblks: Int = 0, keepcost: Int = 0
}
@_silgen_name("mallinfo2") private func c_mallinfo2() -> CMallinfo2
#endif

struct AllocationSnapshot {
    /// Live heap blocks, or nil where the platform does not expose a count.
    var blocks: Int?
    /// Live heap bytes.
    var bytes: Int

    static func take() -> AllocationSnapshot {
        #if canImport(Darwin)
        var zones: UnsafeMutablePointer<vm_address_t>?
        var count: UInt32 = 0
        var blocks = 0
        var bytes = 0
        if malloc_get_all_zones(mach_task_self_, nil, &zones, &count) == KERN_SUCCESS,
           let zones {
            for i in 0..<Int(count) {
                let zone = UnsafeMutableRawPointer(bitPattern: UInt(zones[i]))?
                    .assumingMemoryBound(to: malloc_zone_t.self)
                var stats = malloc_statistics_t()
                malloc_zone_statistics(zone, &stats)
                blocks += Int(stats.blocks_in_use)
                bytes += Int(stats.size_in_use)
            }
        }
        return AllocationSnapshot(blocks: blocks, bytes: bytes)
        #elseif canImport(Glibc)
        let info = c_mallinfo2()
        return AllocationSnapshot(blocks: nil, bytes: info.uordblks)
        #else
        return AllocationSnapshot(blocks: nil, bytes: 0)
        #endif
    }
}

/// Decode `iterations` documents, keeping every result alive, and report the live heap
/// delta per decoded value. `retain` must store its argument somewhere the optimiser
/// cannot see through — otherwise the whole decode is dead code and the answer is zero.
func measureAllocations<T>(
    iterations: Int,
    _ decode: () -> T?
) -> (blocks: Double?, bytes: Double) {
    var kept: [T] = []
    kept.reserveCapacity(iterations)

    // Warm up: first-call caches, any lazily-created singletons, and the array's own
    // storage growth must not land inside the measured window.
    for _ in 0..<min(64, iterations) { if let v = decode() { kept.append(v) } }
    kept.removeAll(keepingCapacity: true)

    let before = AllocationSnapshot.take()
    for _ in 0..<iterations { if let v = decode() { kept.append(v) } }
    let after = AllocationSnapshot.take()

    let blocks = (before.blocks).flatMap { b in
        (after.blocks).map { Double($0 - b) / Double(iterations) }
    }
    let bytes = Double(after.bytes - before.bytes) / Double(iterations)

    // Keep `kept` observably alive past the second snapshot.
    if kept.count == Int.max { print(kept.count) }
    return (blocks, bytes)
}
