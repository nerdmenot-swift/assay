// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The compile-time key dispatcher. docs/PERFORMANCE.md §4.2.
//
// This is simdjson's `key_selector.h` tier 1, run at macro-expansion time instead of at
// `consteval` time. In simdjson's own words:
//
//   Many small key sets can be told apart by inspecting a *single* 8-bit window of the
//   key bytes -- and that window need not be byte-aligned. Because every JSON key is
//   terminated by a `"`, the bytes at and before a key's length are well defined for any
//   key at least that long: byte i is the key character when i is inside the key and the
//   closing quote when i == len.
//
// Two details make it work, and both are non-obvious:
//
//   * The virtual quote byte. At index == length the key's byte is *defined* to be `"`
//     (0x22) rather than out of bounds. That is what separates {"jo","joe"} with no
//     length test at all.
//
//   * The unaligned shift. Allowing a shift of 1..7 mixes bits from two adjacent bytes
//     and discriminates key sets no aligned byte can. simdjson's worked example: the
//     partial_tweets keys collide at every aligned position 0, 1 and 2, yet the eight
//     bits starting at bit offset 2 are unique across all seven.
//
// Aliases fall out for free: flatten every alias into the candidate set before searching,
// mapping several window values to one field index. serde does the same thing as extra
// match arms at runtime; here it costs nothing.
//===----------------------------------------------------------------------===//

/// A key as the dispatcher sees it: the wire bytes, and which declared field it selects.
struct Candidate {
    var wireKey: String
    var fieldIndex: Int
}

struct WindowPlan {
    var byteOffset: Int
    var shift: UInt8
    /// 256 entries; `fieldCount` means "no candidate".
    var table: [UInt8]
}

enum WindowSearch {

    /// Byte at `idx`, with `"` standing in past the end.
    private static func byteAt(_ key: [UInt8], _ idx: Int) -> UInt8 {
        idx < key.count ? key[idx] : 0x22
    }

    private static func windowValue(_ key: [UInt8], _ offset: Int, _ shift: UInt8) -> UInt8 {
        let b0 = UInt16(byteAt(key, offset))
        let b1 = UInt16(byteAt(key, offset + 1))
        let pair = b0 | (b1 << 8)
        return UInt8(truncatingIfNeeded: pair >> UInt16(shift))
    }

    /// Search `(byteOffset, shift)` for a window whose value is distinct across every
    /// candidate. Returns nil when no such window exists — the caller then falls back to
    /// length bucketing (§4.3).
    static func search(_ candidates: [Candidate], fieldCount: Int) -> WindowPlan? {
        guard !candidates.isEmpty else { return nil }
        let keys = candidates.map { Array($0.wireKey.utf8) }
        guard let minLen = keys.map(\.count).min() else { return nil }

        // Duplicate wire keys cannot be told apart by any window; the macro rejects them
        // separately with a real diagnostic, but guard here too.
        if Set(candidates.map(\.wireKey)).count != candidates.count { return nil }

        for offset in 0...minLen {
            for shift in UInt8(0)..<8 {
                // Confine the two-byte read so it never crosses the shortest key's
                // closing quote into uncontrolled value bytes.
                if shift != 0 && offset + 1 > minLen { continue }

                var seen = [UInt8: Int]()
                var distinct = true
                for (i, k) in keys.enumerated() {
                    let w = windowValue(k, offset, shift)
                    if seen[w] != nil { distinct = false; break }
                    seen[w] = i
                }
                guard distinct else { continue }

                var table = [UInt8](repeating: UInt8(fieldCount), count: 256)
                for (i, k) in keys.enumerated() {
                    table[Int(windowValue(k, offset, shift))] =
                        UInt8(candidates[i].fieldIndex)
                }
                return WindowPlan(byteOffset: offset, shift: shift, table: table)
            }
        }
        return nil
    }

    /// A window for ONE length bucket of the fallback dispatch: which keys each window
    /// value selects, as indices into the bucket.
    struct BucketPlan {
        var byteOffset: Int
        var shift: UInt8
        /// Window value -> bucket indices, in bucket order. Sorted by window value.
        var groups: [(value: UInt8, members: [Int])]
    }

    /// The per-bucket search the fallback uses when no global window exists.
    ///
    /// `search` needs one window distinct across EVERY key, which is a birthday bound:
    /// realistic names lose it at about 13 fields and same-prefix synthetic keys at 11
    /// (Benchmarks/RESULTS.md, "The field-count sweep"). A length bucket is a much smaller
    /// set, and inside one all keys share a length, so every byte up to and including the
    /// closing quote is defined for all of them.
    ///
    /// This does NOT insist on a perfect window. It takes the one whose largest collision
    /// group is smallest (ties: fewest expected compares), because some key sets have no
    /// perfect window at all — `k00`…`k63` differ only in two decimal digits whose useful
    /// bits are not contiguous — and a chain of 7 is still an order of magnitude better
    /// than a chain of 64. Realistic names split perfectly in every bucket up to 48 fields.
    ///
    /// Returns nil when no window separates anything; the caller keeps the linear chain.
    /// What a linear chain over `keys` costs, in bytes compared, averaged over which key is
    /// the one being looked up. A candidate tested before the target costs its common
    /// prefix with the target plus the one byte that differs; the target itself costs its
    /// full length either way and is left out, since a window pays it too.
    ///
    /// This is what decides whether a bucket gets a window, and it exists because a window is
    /// not free at COMPILE time: measured 2026-09-19 at +12.7% (~20 ms/type at 24 fields) on
    /// a realistic key set whose runtime gained nothing, because realistic names differ in
    /// their first byte and a failed `keyMatches` there costs one compare.
    static func chainCost(_ keys: [String]) -> Double {
        let bytes = keys.map { Array($0.utf8) }
        guard bytes.count > 1 else { return 0 }
        var total = 0
        for (i, target) in bytes.enumerated() {
            for other in bytes[..<i] {
                var p = 0
                while p < target.count, p < other.count, target[p] == other[p] { p += 1 }
                total += p + 1
            }
        }
        return Double(total) / Double(bytes.count)
    }

    static func bucketSearch(_ keys: [String]) -> BucketPlan? {
        let bytes = keys.map { Array($0.utf8) }
        guard bytes.count > 1, let len = bytes.first?.count,
              bytes.allSatisfy({ $0.count == len }) else { return nil }

        var best: (maxGroup: Int, cost: Int, offset: Int, shift: UInt8)?
        for offset in 0...len {
            for shift in UInt8(0)..<8 {
                // Byte `len` is the closing quote; byte `len + 1` is not the key's.
                if shift != 0 && offset + 1 > len { continue }
                var counts = [UInt8: Int]()
                for k in bytes { counts[windowValue(k, offset, shift), default: 0] += 1 }
                let maxGroup = counts.values.max() ?? 0
                let cost = counts.values.reduce(0) { $0 + $1 * $1 }
                if best.map({ (maxGroup, cost) < ($0.maxGroup, $0.cost) }) ?? true {
                    best = (maxGroup, cost, offset, shift)
                }
                if maxGroup == 1 { break }
            }
            if best?.maxGroup == 1 { break }
        }
        guard let best, best.maxGroup < bytes.count else { return nil }

        var groups: [UInt8: [Int]] = [:]
        for (i, k) in bytes.enumerated() {
            groups[windowValue(k, best.offset, best.shift), default: []].append(i)
        }
        return BucketPlan(
            byteOffset: best.offset, shift: best.shift,
            groups: groups.keys.sorted().map { ($0, groups[$0]!) })
    }
}
