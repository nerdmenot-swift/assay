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
}
