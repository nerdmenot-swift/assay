// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Property lists: a differential against `PropertyListSerialization`, and a fuzz arm.
//
// THE FUZZ ARM IS THE POINT HERE, more than the differential. Every other format this library
// reads is a document scanned front to back, where a mutated byte produces a parse error a few
// bytes later. A binary plist is a random-access object graph steered by a **trailer at the
// end of the file**: flipping one byte there changes the offset width, the reference width,
// the object count or the address of the offset table, and every subsequent read lands
// somewhere the file did not intend. That is the shape that produces out-of-bounds reads and
// integer traps rather than parse errors, and the only honest way to look for them is to
// generate the bytes and run them.
//
// It found one before it had run a hundred inputs: `Int(someUInt64)` on a trailer field traps
// on anything above `Int.max`, so a malformed document crashed instead of reporting. Fixed in
// `BinaryPlist.swift`; this is what keeps it fixed.
//
// The differential half writes with Foundation and reads with Assay, which is the strongest
// available direction: the bytes come from the implementation being compared against, so
// nothing about Assay's reader shaped its own input.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayCore
import AssayPlist

/// Structural comparison. Numeric TYPE is deliberately not compared across the boundary:
/// Foundation returns `NSNumber`, which does not distinguish an integer from a double the way
/// `RawValue` does, so comparing tags would test the bridge rather than the parser.
func plistEquivalent(_ mine: RawValue, _ theirs: Any) -> Bool {
    switch mine {
    case .null:            return theirs is NSNull
    case .bool(let b):     return (theirs as? NSNumber)?.boolValue == b
    case .int(let i):      return (theirs as? NSNumber)?.int64Value == i
    case .double(let d):   return (theirs as? NSNumber)?.doubleValue == d
    case .string(let s):
        if let t = theirs as? String { return t == s }
        if let dt = theirs as? Data { return dt.base64EncodedString() == s }
        return false
    case .sequence(let items):
        guard let a = theirs as? [Any], a.count == items.count else { return false }
        for (x, y) in zip(items, a) where !plistEquivalent(x, y) { return false }
        return true
    case .mapping(let members):
        guard let d = theirs as? [String: Any], d.count == members.count else { return false }
        for m in members {
            guard let v = d[m.key], plistEquivalent(m.value, v) else { return false }
        }
        return true
    }
}

/// The values the differential round-trips. Chosen to cover every object marker the reader
/// implements a branch for, since a marker with no case here is a marker with no oracle.
func plistOracleValues() -> [Any] {
    var wide: [String: Any] = [:]
    for i in 0..<40 { wide["key\(i)"] = i }
    return [
        ["s": "x", "n": 42, "b": true, "f": false] as [String: Any],
        ["ints": [0, 1, -1, 127, 128, 255, 256, 65535, 65536,
                  2_147_483_647, 9_223_372_036_854_775_807, -9_223_372_036_854_775_808]],
        ["reals": [0.0, -0.0, 0.5, -1.25, 1e300, 1e-300]],
        ["strings": ["", "a", "héllo €", "a longer ASCII string past the fifteen-byte nibble",
                     "日本語のテキスト、これも十五バイトを超えます"]],
        ["data": Data([0]), "data2": Data([1, 2, 3]), "data3": Data(repeating: 7, count: 300)],
        ["nested": ["a": ["b": ["c": ["d": "deep"]]]]],
        ["empty_dict": [String: Any](), "empty_array": [Any]()],
        wide,
        // A value repeated many times: Foundation's writer deduplicates it into one shared
        // object with many references, which is exactly the SHARED (not cyclic, not
        // amplifying) case the reader must accept.
        ["a": "same", "b": "same", "c": "same", "d": ["same", "same", "same"]],
        [1, 2, 3] as [Any],
        "a bare string root",
    ]
}

func runPlistDifferential() throws -> (Int, Int) {
    var binary = 0
    var xml = 0
    for v in plistOracleValues() {
        for (format, counter) in [(PropertyListSerialization.PropertyListFormat.binary, 0),
                                  (.xml, 1)] {
            guard let data = try? PropertyListSerialization.data(
                fromPropertyList: v, format: format, options: 0) else {
                fail("Foundation could not write \(v) as \(format)")
                continue
            }
            var sink = IssueSink(limits: .default)
            guard let mine = Plist.decode(Array(data), into: &sink, limits: .default) else {
                fail("plist: rejected a document Foundation wrote (\(format)): \(sink.issues)")
                continue
            }
            if !plistEquivalent(mine, v) {
                fail("plist: disagreed with Foundation on \(v) (\(format))")
            }
            if counter == 0 { binary += 1 } else { xml += 1 }
        }
    }
    return (binary, xml)
}

/// Mutate and truncate documents Foundation wrote. No crashes, no hangs, no traps — the
/// decoder may reject anything it likes, but it must *return*.
func runPlistFuzz() throws -> Int {
    var rng = SplitMix64(seed: 0x9E37_79B9_7F4A_7C15)
    var seeds: [[UInt8]] = []
    for v in plistOracleValues() {
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            if let d = try? PropertyListSerialization.data(
                fromPropertyList: v, format: format, options: 0) {
                seeds.append(Array(d))
            }
        }
    }

    var runs = 0
    for seed in seeds {
        // Truncation at every length. A binary plist keeps its trailer at the END, so
        // truncation is not a mild mutation here — it removes the map the reader steers by
        // and leaves whatever bytes happen to lie at the cut to be read as one.
        for cut in stride(from: 0, to: seed.count, by: max(1, seed.count / 64)) {
            var sink = IssueSink(limits: .default)
            _ = Plist.decode(Array(seed[0..<cut]), into: &sink, limits: .default)
            runs += 1
        }

        // Single-byte mutations, weighted towards the trailer, where the damage is.
        for _ in 0..<220 {
            var bytes = seed
            let inTrailer = bytes.count > 32 && (rng.next() % 2 == 0)
            let i = inTrailer
                ? bytes.count - 32 + Int(rng.next() % 32)
                : Int(rng.next() % UInt64(bytes.count))
            bytes[i] = UInt8(truncatingIfNeeded: rng.next())
            var sink = IssueSink(limits: .default)
            _ = Plist.decode(bytes, into: &sink, limits: .default)
            runs += 1
        }

        // Whole-trailer randomisation: every offset width, reference width, object count and
        // table address at once, which single-byte mutation reaches only by accident.
        for _ in 0..<120 where seed.count > 32 {
            var bytes = seed
            for j in (bytes.count - 32)..<bytes.count {
                bytes[j] = UInt8(truncatingIfNeeded: rng.next())
            }
            var sink = IssueSink(limits: .default)
            _ = Plist.decode(bytes, into: &sink, limits: .default)
            runs += 1
        }
    }

    // Pure noise behind a valid magic, so the reader meets trailers no writer would produce.
    for _ in 0..<3_000 {
        var bytes = Array("bplist00".utf8)
        let n = 32 + Int(rng.next() % 200)
        for _ in 0..<n { bytes.append(UInt8(truncatingIfNeeded: rng.next())) }
        var sink = IssueSink(limits: .default)
        _ = Plist.decode(bytes, into: &sink, limits: .default)
        runs += 1
    }
    return runs
}
