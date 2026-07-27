// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Numbers. docs/PERFORMANCE.md §6.
//
// Two decisions, both against the obvious instinct:
//
//   * NO SWAR for integers. The eight-digit multiply trick is a *loss* at API widths
//     (1-6 digits: IDs, counts, status codes). simdjson invokes it only after the
//     decimal point; yyjson never uses it for integers. sonic-rs even documents an
//     anti-SIMD note: on AMD Zen the SSE path saturates the FP ports.
//
//   * NO hand-rolled Eisel-Lemire in v1. `Double(String)` is now pure Swift
//     (swiftlang/swift#85797) with a Clinger fast path, an FMA 19-digit path, and
//     99%-coverage interval arithmetic. Go's adoption of Eisel-Lemire improved the
//     *primitive* 44% and end-to-end canada.json by 1.08x. Reimplementing it for ~8%
//     on the most float-dense file in existence is not phase-1 work.
//
// What is not negotiable is correct rounding. IkigaJSON's `strtodSpan` does
// `result *= pow(10, exponent)` and is not correctly rounded; that is a bug, not a
// trade-off, and it is the reason this file defers to the stdlib rather than
// improvising.
//===----------------------------------------------------------------------===//

extension AssayReader {

    /// Monomorphic signed-integer scan.
    ///
    /// Accumulates **negatively** (`acc = acc &* 10 &- digit`) so `Int64.min` needs no
    /// special case — the same trick Foundation uses in `_parseIntegerDigits`. Overflow
    /// checks are skipped for the first 18 digits, where overflow is arithmetically
    /// impossible; that removes a branch per digit on every realistic input.
    @inlinable
    public mutating func scanInt64() -> Int64? {
        skipWhitespace()
        guard cursor < count else { return nil }

        var negative = false
        if unsafe base[cursor] == 0x2D {
            negative = true
            cursor &+= 1
        }
        guard cursor < count else { return nil }

        let firstDigit = cursor
        var acc: Int64 = 0
        var n = 0

        // Fast lane: up to 18 digits cannot overflow Int64, so no per-digit check.
        while cursor < count, n < 18 {
            let c = unsafe base[cursor]
            guard c >= 0x30, c <= 0x39 else { break }
            acc = acc &* 10 &- Int64(c &- 0x30)
            cursor &+= 1
            n &+= 1
        }
        guard n > 0 else {
            cursor = firstDigit
            return nil
        }

        // Slow lane: 19th digit onward needs the real check.
        while cursor < count {
            let c = unsafe base[cursor]
            guard c >= 0x30, c <= 0x39 else { break }
            let (m, o1) = acc.multipliedReportingOverflow(by: 10)
            if o1 { return nil }
            let (s, o2) = m.subtractingReportingOverflow(Int64(c &- 0x30))
            if o2 { return nil }
            acc = s
            cursor &+= 1
        }

        // A number with a fraction or exponent is not an integer. Rewind and let the
        // caller decide — silently truncating "8080.5" to 8080 is the kind of quiet
        // wrongness this library exists to avoid.
        if cursor < count {
            let c = unsafe base[cursor]
            if c == 0x2E || c == 0x65 || c == 0x45 {
                cursor = firstDigit
                if negative { cursor &-= 1 }
                return nil
            }
        }

        if negative { return acc }
        let (v, o) = Int64(0).subtractingReportingOverflow(acc)
        return o ? nil : v
    }

    /// Powers of ten that are *exactly* representable as a `Double`. 10^22 is the last
    /// one; 10^23 is not. This bound is what makes the Clinger fast path provably
    /// correctly rounded rather than merely close.
    @usableFromInline
    static let exactPowersOf10: [Double] = [
        1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
        1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
    ]

    /// Scan a JSON number into a `Double`.
    ///
    /// Three tiers, per docs/research/perf-dispatch-and-hot-path.md §2.6:
    ///
    ///   (a) **Clinger fast path.** If the significand fits in 2^53 and the decimal
    ///       exponent is within ±22, one multiply or divide against an exactly-representable
    ///       power of ten is *correctly rounded* — this is Clinger's 1990 result, not an
    ///       approximation. Covers essentially all human-authored and API-generated JSON:
    ///       prices, coordinates, percentages, durations.
    ///   (b) Integer-shaped input with no fraction or exponent: convert from Int64.
    ///   (c) Anything else: fall back to the stdlib, which since swiftlang/swift#85797 is
    ///       pure Swift with its own Clinger path, an FMA 19-digit path, and 99%-coverage
    ///       interval arithmetic.
    ///
    /// The point of (a) is not that the stdlib is slow — it is that reaching the stdlib
    /// requires materialising a `String`, and the stdlib's own 20% claim for the pure-Swift
    /// rewrite was attributed almost entirely to removing exactly that copy. This keeps the
    /// common case on raw bytes.
    ///
    /// **Correct rounding is not negotiable.** IkigaJSON's `strtodSpan` does
    /// `result *= pow(10, exponent)` and is not correctly rounded; that is a bug, not a
    /// trade-off, and it is why tier (a) is bounded rather than general.
    @inlinable
    public mutating func scanDouble() -> Double? {
        skipWhitespace()
        let start = cursor
        guard cursor < count else { return nil }

        var negative = false
        if unsafe base[cursor] == 0x2D {
            negative = true
            cursor &+= 1
        }

        // Significand, accumulated across the decimal point. `digits` counts significant
        // digits so overflow of the 2^53 budget can be detected exactly.
        var significand: UInt64 = 0
        var digits = 0
        var fractionDigits = 0
        var sawDigit = false
        var tooManyDigits = false

        while cursor < count {
            let c = unsafe base[cursor]
            guard c >= 0x30, c <= 0x39 else { break }
            sawDigit = true
            if digits < 19 {
                significand = significand &* 10 &+ UInt64(c &- 0x30)
                digits &+= 1
            } else {
                tooManyDigits = true
            }
            cursor &+= 1
        }

        var isInteger = true
        if cursor < count, unsafe base[cursor] == 0x2E {
            isInteger = false
            cursor &+= 1
            while cursor < count {
                let c = unsafe base[cursor]
                guard c >= 0x30, c <= 0x39 else { break }
                sawDigit = true
                if digits < 19 {
                    significand = significand &* 10 &+ UInt64(c &- 0x30)
                    digits &+= 1
                    fractionDigits &+= 1
                } else {
                    tooManyDigits = true
                }
                cursor &+= 1
            }
        }

        guard sawDigit else {
            cursor = start
            return nil
        }

        var exponent = -fractionDigits
        if cursor < count, unsafe (base[cursor] == 0x65 || base[cursor] == 0x45) {
            isInteger = false
            cursor &+= 1
            var expNegative = false
            if cursor < count {
                let c = unsafe base[cursor]
                if c == 0x2D { expNegative = true; cursor &+= 1 }
                else if c == 0x2B { cursor &+= 1 }
            }
            var expValue = 0
            var sawExpDigit = false
            while cursor < count {
                let c = unsafe base[cursor]
                guard c >= 0x30, c <= 0x39 else { break }
                sawExpDigit = true
                if expValue < 10_000 { expValue = expValue &* 10 &+ Int(c &- 0x30) }
                cursor &+= 1
            }
            guard sawExpDigit else {
                cursor = start
                return nil
            }
            exponent &+= expNegative ? -expValue : expValue
        }

        // (b) integer-shaped
        if isInteger, !tooManyDigits, significand <= 9_007_199_254_740_992 {
            let d = Double(significand)
            return negative ? -d : d
        }

        // (a) Clinger fast path — exact when the significand is exactly representable and
        // the power of ten is too.
        if !tooManyDigits, significand <= 9_007_199_254_740_992, exponent >= -22, exponent <= 22 {
            let s = Double(significand)
            let d: Double = exponent >= 0
                ? s * AssayReader.exactPowersOf10[exponent]
                : s / AssayReader.exactPowersOf10[-exponent]
            return negative ? -d : d
        }

        // (c) hard cases — subnormals, >19 significant digits, huge exponents.
        return slowDouble(from: start)
    }

    /// Cold. Materialises a `String` and defers to the stdlib's correctly-rounded parser.
    @inline(never)
    @usableFromInline
    mutating func slowDouble(from start: Int) -> Double? {
        let buf = unsafe UnsafeBufferPointer(start: base + start, count: cursor - start)
        let s = unsafe String(decoding: buf, as: UTF8.self)
        guard let d = Double(s) else {
            cursor = start
            return nil
        }
        return d
    }

    @inlinable
    public mutating func scanBool() -> Bool? {
        skipWhitespace()
        guard cursor < count else { return nil }
        if unsafe base[cursor] == 0x74 {
            guard cursor &+ 4 <= count,
                  unsafe base[cursor &+ 1] == 0x72,
                  unsafe base[cursor &+ 2] == 0x75,
                  unsafe base[cursor &+ 3] == 0x65 else { return nil }
            cursor &+= 4
            return true
        }
        if unsafe base[cursor] == 0x66 {
            guard cursor &+ 5 <= count,
                  unsafe base[cursor &+ 1] == 0x61,
                  unsafe base[cursor &+ 2] == 0x6C,
                  unsafe base[cursor &+ 3] == 0x73,
                  unsafe base[cursor &+ 4] == 0x65 else { return nil }
            cursor &+= 5
            return false
        }
        return nil
    }

    /// Consume a literal `null`. Returns false without moving the cursor otherwise.
    @inlinable
    public mutating func scanNull() -> Bool {
        skipWhitespace()
        guard cursor &+ 4 <= count,
              unsafe base[cursor] == 0x6E,
              unsafe base[cursor &+ 1] == 0x75,
              unsafe base[cursor &+ 2] == 0x6C,
              unsafe base[cursor &+ 3] == 0x6C else { return false }
        cursor &+= 4
        return true
    }
}

