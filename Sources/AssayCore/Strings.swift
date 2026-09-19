// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Strings — the second-biggest win, obtained by not creating them.
// docs/PERFORMANCE.md §5.
//
// Two Swift-specific traps this file is built around:
//
//   * `String(decoding:as: UTF8.self)` validates and repairs — two passes over the
//     bytes. Correct default, wrong hot path. Assay validates the whole buffer once at
//     entry (see UTF8Validation.swift) and then treats every range carved out of it as
//     known-valid.
//
//   * `String(unsafeUninitializedCapacity:)` (SE-0263, *not* SE-0309) branches on the
//     **declared** capacity, not the written count. Declare 64, write 3, and it
//     heap-allocates a 64-byte __StringStorage. So the declared capacity must be the
//     true byte count — which the scanner knows exactly, because it found the closing
//     quote before constructing anything.
//
// And one claim that must never be made: "we avoid a String allocation per key" is only
// true for keys longer than the SSO threshold. Short keys already produce immortal,
// non-allocating Strings. The unambiguous win is *no Dictionary and no hashing per
// object* — which is the bigger term anyway.
//===----------------------------------------------------------------------===//

extension AssayReader {

    /// Scan a string value. The fast path — no backslash anywhere — is a contiguous byte
    /// range that goes straight into a `String` with one copy.
    @inlinable
    public mutating func scanString() -> String? {
        skipWhitespace()
        guard cursor < count, unsafe base[cursor] == 0x22 else { return nil }
        cursor &+= 1
        let start = cursor

        while cursor < count {
            let c = unsafe base[cursor]
            if c == 0x22 {
                let n = cursor &- start
                let s = makeString(at: start, count: n)
                cursor &+= 1
                return s
            }
            if c == 0x5C {
                return scanStringSlow(from: start)
            }
            // RFC 8259 §7: a control character below 0x20 MUST be escaped. Accepting a raw
            // tab or newline inside a string is the single most common laxity in a
            // hand-written JSON parser, and it is one comparison to refuse.
            if c < 0x20 { return nil }
            cursor &+= 1
        }
        return nil
    }

    /// The no-escape path. Capacity is the exact byte count, so ≤15-byte values stay in
    /// the small-string representation: no allocation, no retain/release, no validation.
    /// The pointer is hoisted out of the closure; see `AssayReader.string(from:to:)` for
    /// why. `base + offset` written inside the closure captures `self`, which is
    /// `~Copyable`, and the closure stops specializing.
    @inlinable @inline(__always)
    func makeString(at offset: Int, count n: Int) -> String {
        let src = unsafe base + offset
        return unsafe String(unsafeUninitializedCapacity: n) { buffer in
            unsafe buffer.baseAddress!.update(from: src, count: n)
            return n
        }
    }

    /// The escape path: cold-marked, resolves `\uXXXX` including surrogate pairs.
    ///
    /// The fork between "can memcpy" and "must transform" is one of the largest in any
    /// decoder, which is why the corpus has a dedicated `escaped` shape.
    ///
    /// SIZED BY THE STRING, NOT THE DOCUMENT. Until 2026-09-19 this reserved
    /// `(count - start) & 0xFFFF` bytes for its buffer — the rest of the DOCUMENT, masked to
    /// 16 bits — for every escaped string, however short. Decoding a ~100 kB document whose
    /// values all carried one `\n` allocated 318 MB, 1,986× the least its result needed, and
    /// heap per call grew with elements × document size: slope 2.00 on `count.py scale`'s
    /// `escaped-elements` axis, while instructions stayed linear, because reserving memory
    /// does not touch it. No timing ever showed it; the floors did (docs/EFFICIENCY.md, row 6).
    ///
    /// A decoded string is never longer than its escaped source — an escape shrinks
    /// (`\n` 2→1, `\uXXXX` 6→≤3, a surrogate pair 12→4) — so the distance to the closing
    /// quote is an exact upper bound. Under `stackUnescapeLimit` the bytes go to the stack
    /// and the only heap block is the String itself, none at all when it fits inline; above
    /// it they go straight into the String's own storage. One pass to find the quote, one
    /// to decode, and no reallocation in either.
    @inline(never)
    @usableFromInline
    mutating func scanStringSlow(from start: Int) -> String? {
        var end = cursor
        while end < count {
            let c = unsafe base[end]
            if c == 0x22 { break }
            end &+= c == 0x5C ? 2 : 1
        }
        let bound = min(end, count) &- start
        if bound <= Self.stackUnescapeLimit {
            return unsafe withUnsafeTemporaryAllocation(of: UInt8.self,
                                                        capacity: max(bound, 1)) { buffer in
                let out = buffer.baseAddress!
                guard let n = unsafe unescape(from: start, into: out) else { return nil }
                return unsafe String(decoding: UnsafeBufferPointer(start: out, count: n),
                                     as: UTF8.self)
            }
        }
        var decoded = true
        let s = unsafe String(unsafeUninitializedCapacity: bound) { buffer in
            guard let n = unsafe unescape(from: start, into: buffer.baseAddress!) else {
                decoded = false
                return 0
            }
            return n
        }
        return decoded ? s : nil
    }

    /// `withUnsafeTemporaryAllocation`'s stack cliff: above 1,024 bytes it heap-allocates
    /// anyway (CLAUDE.md, corrected premises), so there is nothing to gain past it.
    @usableFromInline static var stackUnescapeLimit: Int { 1_024 }

    /// Unescape the string that began at `start` into `out`, which the caller has sized to
    /// the distance to the closing quote. Returns the byte count written, with the cursor
    /// past the quote; nil on a malformed string, with `escapeErrorAt` set where one applies.
    @usableFromInline
    mutating func unescape(from start: Int, into out: UnsafeMutablePointer<UInt8>) -> Int? {
        var n = cursor &- start
        unsafe out.update(from: base + start, count: n)

        while cursor < count {
            let c = unsafe base[cursor]
            if c == 0x22 {
                cursor &+= 1
                return n
            }
            if c != 0x5C {
                if c < 0x20 { return nil }        // RFC 8259 §7, as on the fast path
                unsafe out[n] = c
                n &+= 1
                cursor &+= 1
                continue
            }
            // escape
            let escapeStart = cursor
            cursor &+= 1
            // A backslash as the last byte of the input. There is no closing quote to scan
            // to, so `skipString` cannot consume the value — but naming the escape is still
            // a better answer than `must be a string`, and it stops the caller adding a
            // type mismatch on top of the malformed-document error the truncation earns.
            guard cursor < count else {
                escapeErrorAt = escapeStart
                return nil
            }
            let e = unsafe base[cursor]
            cursor &+= 1
            let byte: UInt8
            switch e {
            case 0x22: byte = 0x22                // \"
            case 0x5C: byte = 0x5C                // backslash
            case 0x2F: byte = 0x2F                // /
            case 0x62: byte = 0x08                // \b
            case 0x66: byte = 0x0C                // \f
            case 0x6E: byte = 0x0A                // \n
            case 0x72: byte = 0x0D                // \r
            case 0x74: byte = 0x09                // \t
            case 0x75:                            // \uXXXX
                guard let scalar = scanUnicodeEscape() else {
                    // A lone surrogate or a non-hex digit. Remember where, then scan on
                    // to the closing quote so the value is consumed: until 2026-09-10
                    // this returned with the cursor mid-string and the caller reported
                    // "must be a string" followed by "is not a well-formed document".
                    escapeErrorAt = escapeStart
                    cursor = escapeStart
                    _ = skipString()
                    return nil
                }
                n &+= unsafe writeUTF8(scalar, to: out + n)
                continue
            default:
                // ANY OTHER ESCAPE IS INVALID, and it gets the same treatment the `\u`
                // arm got on 2026-09-10 — which was written for exactly this and applied
                // to one arm of two. Returning with the cursor mid-string made the caller
                // report `must be a string, found y"`: the wrong problem, quoting the
                // garbage that followed the bad escape. Remember where, rewind, and scan
                // on to the closing quote so the value is consumed and `failed` can say
                // `invalid_escape` instead.
                escapeErrorAt = escapeStart
                cursor = escapeStart
                _ = skipString()
                return nil
            }
            unsafe out[n] = byte
            n &+= 1
        }
        return nil
    }


    /// Branch-free hex nibble decode, after swift-extras-json's `hexAsciiTo4Bits`.
    /// IkigaJSON's `firstIndex(of:)` linear search over a 16-element array is the
    /// version not to copy.
    @inlinable @inline(__always)
    func hexNibble(_ c: UInt8) -> UInt32? {
        if c >= 0x30 && c <= 0x39 { return UInt32(c &- 0x30) }
        if c >= 0x61 && c <= 0x66 { return UInt32(c &- 0x61 &+ 10) }
        if c >= 0x41 && c <= 0x46 { return UInt32(c &- 0x41 &+ 10) }
        return nil
    }

    @usableFromInline
    mutating func scanHex4() -> UInt32? {
        guard cursor &+ 4 <= count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 {
            guard let n = hexNibble(unsafe base[cursor &+ i]) else { return nil }
            v = (v << 4) | n
        }
        cursor &+= 4
        return v
    }

    @usableFromInline
    mutating func scanUnicodeEscape() -> UInt32? {
        guard let hi = scanHex4() else { return nil }
        // Not a surrogate — done.
        if hi < 0xD800 || hi > 0xDFFF { return hi }
        // Unpaired low surrogate is invalid.
        guard hi <= 0xDBFF else { return nil }
        // Expect a paired \uDC00-\uDFFF.
        guard cursor &+ 1 < count,
              unsafe base[cursor] == 0x5C,
              unsafe base[cursor &+ 1] == 0x75 else { return nil }
        cursor &+= 2
        guard let lo = scanHex4(), lo >= 0xDC00, lo <= 0xDFFF else { return nil }
        return 0x10000 &+ ((hi &- 0xD800) << 10) &+ (lo &- 0xDC00)
    }

    /// Encode `scalar` as UTF-8 at `out`; returns the byte count (1-4).
    @inlinable @inline(__always)
    func writeUTF8(_ scalar: UInt32, to out: UnsafeMutablePointer<UInt8>) -> Int {
        switch scalar {
        case 0..<0x80:
            unsafe out[0] = UInt8(scalar)
            return 1
        case 0x80..<0x800:
            unsafe out[0] = UInt8(0xC0 | (scalar >> 6))
            unsafe out[1] = UInt8(0x80 | (scalar & 0x3F))
            return 2
        case 0x800..<0x10000:
            unsafe out[0] = UInt8(0xE0 | (scalar >> 12))
            unsafe out[1] = UInt8(0x80 | ((scalar >> 6) & 0x3F))
            unsafe out[2] = UInt8(0x80 | (scalar & 0x3F))
            return 3
        default:
            unsafe out[0] = UInt8(0xF0 | (scalar >> 18))
            unsafe out[1] = UInt8(0x80 | ((scalar >> 12) & 0x3F))
            unsafe out[2] = UInt8(0x80 | ((scalar >> 6) & 0x3F))
            unsafe out[3] = UInt8(0x80 | (scalar & 0x3F))
            return 4
        }
    }
}
