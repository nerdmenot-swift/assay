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
                let s = unsafe makeString(at: start, count: n)
                cursor &+= 1
                return s
            }
            if c == 0x5C {
                return scanStringSlow(from: start)
            }
            cursor &+= 1
        }
        return nil
    }

    /// The no-escape path. Capacity is the exact byte count, so ≤15-byte values stay in
    /// the small-string representation: no allocation, no retain/release, no validation.
    @inlinable @inline(__always)
    func makeString(at offset: Int, count n: Int) -> String {
        unsafe String(unsafeUninitializedCapacity: n) { buffer in
            unsafe buffer.baseAddress!.update(from: base + offset, count: n)
            return n
        }
    }

    /// The escape path: cold-marked, copies into a local buffer, resolves `\uXXXX`
    /// including surrogate pairs.
    ///
    /// The fork between "can memcpy" and "must transform" is one of the largest in any
    /// decoder, which is why the corpus has a dedicated `escaped` shape.
    @inline(never)
    @usableFromInline
    mutating func scanStringSlow(from start: Int) -> String? {
        var out = [UInt8]()
        out.reserveCapacity((count &- start) & 0xFFFF)
        unsafe out.append(contentsOf: UnsafeBufferPointer(start: base + start, count: cursor - start))

        while cursor < count {
            let c = unsafe base[cursor]
            if c == 0x22 {
                cursor &+= 1
                return unsafe out.withUnsafeBufferPointer {
                    unsafe String(decoding: $0, as: UTF8.self)
                }
            }
            if c != 0x5C {
                out.append(c)
                cursor &+= 1
                continue
            }
            // escape
            cursor &+= 1
            guard cursor < count else { return nil }
            let e = unsafe base[cursor]
            cursor &+= 1
            switch e {
            case 0x22: out.append(0x22)          // \"
            case 0x5C: out.append(0x5C)          // backslash
            case 0x2F: out.append(0x2F)          // /
            case 0x62: out.append(0x08)          // \b
            case 0x66: out.append(0x0C)          // \f
            case 0x6E: out.append(0x0A)          // \n
            case 0x72: out.append(0x0D)          // \r
            case 0x74: out.append(0x09)          // \t
            case 0x75:                            // \uXXXX
                guard let scalar = scanUnicodeEscape() else { return nil }
                appendUTF8(scalar, to: &out)
            default:
                return nil
            }
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

    @inlinable @inline(__always)
    func appendUTF8(_ scalar: UInt32, to out: inout [UInt8]) {
        switch scalar {
        case 0..<0x80:
            out.append(UInt8(scalar))
        case 0x80..<0x800:
            out.append(UInt8(0xC0 | (scalar >> 6)))
            out.append(UInt8(0x80 | (scalar & 0x3F)))
        case 0x800..<0x10000:
            out.append(UInt8(0xE0 | (scalar >> 12)))
            out.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (scalar & 0x3F)))
        default:
            out.append(UInt8(0xF0 | (scalar >> 18)))
            out.append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
            out.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (scalar & 0x3F)))
        }
    }
}
