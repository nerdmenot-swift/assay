// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Whole-buffer UTF-8 validation, once, up front. docs/PERFORMANCE.md §5.4.
//
// The measured case for doing it this way rather than per-string: serde_json calls
// `str::from_utf8` per string and it costs **1.65x** on twitter.json (from_slice 2.2895ms
// vs from_str 1.3842ms). sonic-rs made exactly this change — one `simdutf8` pass up
// front, then `from_utf8_unchecked` everywhere.
//
// The trade is that Assay does strictly *more* validation than a lazy decoder: it
// validates bytes it may never decode. The cost is one linear pass with excellent ILP,
// and in exchange every subsequent String construction skips validation entirely.
//
// The precise soundness caveat: this is only valid because the input is a single
// contiguous buffer that cannot change underneath the parse. That is a second reason the
// public API takes bytes rather than a stream.
//
// Phase 1 is scalar. The ASCII fast lane is 8-byte SWAR, which is the portable answer;
// a SIMD version goes behind the dispatch seam in phase 4 if the numbers justify it.
//===----------------------------------------------------------------------===//

public enum UTF8Validation {

    /// The length of a leading UTF-8 byte-order mark, 3 or 0. RFC 8259 §8.1 lets a parser
    /// ignore one, `JSONDecoder` does, and every file Notepad saves has one; until
    /// 2026-09-10 Assay reported it as `must be an object, found ﻿{…`. The mark is skipped,
    /// not deleted: offsets stay absolute, so carets and line numbers are unchanged.
    @inlinable
    public static func bomLength(_ base: UnsafePointer<UInt8>, _ count: Int) -> Int {
        guard count >= 3 else { return 0 }
        return unsafe (base[0] == 0xEF && base[1] == 0xBB && base[2] == 0xBF) ? 3 : 0
    }

    /// Returns the byte offset of the first invalid sequence, or nil if the whole buffer
    /// is well-formed UTF-8.
    ///
    /// Rejects what a correct validator must reject and what a naive one does not:
    /// overlong encodings (`C0 AF` for `/`), surrogate halves (`ED A0 80`), and anything
    /// above U+10FFFF. Those are not pedantry — overlongs defeat byte-level filters
    /// applied before decoding, and Swift's `String` guarantees well-formed UTF-8 as a
    /// *type invariant*, so feeding it an unvalidated range is an invariant violation
    /// rather than merely a correctness bug.
    @inlinable
    public static func firstInvalid(
        _ base: UnsafePointer<UInt8>,
        _ count: Int
    ) -> Int? {
        var i = 0

        while i < count {
            // ASCII fast lane: 8 bytes at a time via SWAR. `& 0x8080...` is zero iff all
            // eight bytes are < 0x80. This is the same trick the stdlib's `_allASCII`
            // falls back to on platforms without a vector path.
            while i &+ 8 <= count {
                let word = unsafe UnsafeRawPointer(base + i)
                    .loadUnaligned(as: UInt64.self)
                if word & 0x8080_8080_8080_8080 != 0 { break }
                i &+= 8
            }
            if i >= count { return nil }

            let c0 = unsafe base[i]
            if c0 < 0x80 {
                i &+= 1
                continue
            }

            // Multi-byte. Shape tests follow the same structure as yyjson's
            // is_utf8_seq2/3/4, which reject overlongs and surrogates by construction.
            if c0 >= 0xC2 && c0 <= 0xDF {
                guard i &+ 1 < count, isCont(unsafe base[i &+ 1]) else { return i }
                i &+= 2
            } else if c0 == 0xE0 {
                guard i &+ 2 < count,
                      unsafe base[i &+ 1] >= 0xA0, unsafe base[i &+ 1] <= 0xBF,   // no overlong
                      isCont(unsafe base[i &+ 2]) else { return i }
                i &+= 3
            } else if c0 >= 0xE1 && c0 <= 0xEC {
                guard i &+ 2 < count,
                      isCont(unsafe base[i &+ 1]), isCont(unsafe base[i &+ 2]) else { return i }
                i &+= 3
            } else if c0 == 0xED {
                guard i &+ 2 < count,
                      unsafe base[i &+ 1] >= 0x80, unsafe base[i &+ 1] <= 0x9F,   // no surrogate
                      isCont(unsafe base[i &+ 2]) else { return i }
                i &+= 3
            } else if c0 >= 0xEE && c0 <= 0xEF {
                guard i &+ 2 < count,
                      isCont(unsafe base[i &+ 1]), isCont(unsafe base[i &+ 2]) else { return i }
                i &+= 3
            } else if c0 == 0xF0 {
                guard i &+ 3 < count,
                      unsafe base[i &+ 1] >= 0x90, unsafe base[i &+ 1] <= 0xBF,   // no overlong
                      isCont(unsafe base[i &+ 2]), isCont(unsafe base[i &+ 3]) else { return i }
                i &+= 4
            } else if c0 >= 0xF1 && c0 <= 0xF3 {
                guard i &+ 3 < count,
                      isCont(unsafe base[i &+ 1]),
                      isCont(unsafe base[i &+ 2]),
                      isCont(unsafe base[i &+ 3]) else { return i }
                i &+= 4
            } else if c0 == 0xF4 {
                guard i &+ 3 < count,
                      unsafe base[i &+ 1] >= 0x80, unsafe base[i &+ 1] <= 0x8F,   // <= U+10FFFF
                      isCont(unsafe base[i &+ 2]), isCont(unsafe base[i &+ 3]) else { return i }
                i &+= 4
            } else {
                // 0x80-0xC1 as a lead byte, or 0xF5-0xFF: always invalid.
                return i
            }
        }
        return nil
    }

    @inlinable @inline(__always)
    static func isCont(_ b: UInt8) -> Bool {
        b & 0xC0 == 0x80
    }
}
