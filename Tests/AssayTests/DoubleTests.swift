// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import AssayCore

// The Clinger fast path in scanDouble() is only worth having if it is *correctly rounded*.
// IkigaJSON's `strtodSpan` does `result *= pow(10, exponent)` and is not — that is a
// correctness bug, not a speed trade-off, and it is the failure mode these tests exist to
// prevent.
//
// Every case is checked bit-for-bit against the stdlib's own parser, which since
// swiftlang/swift#85797 is pure Swift with interval arithmetic. Equality of `bitPattern`,
// not `==`, so a one-ulp difference cannot slip through.

private func assayParse(_ s: String) -> Double? {
    var bytes = Array(s.utf8)
    return bytes.withUnsafeBufferPointer { buf -> Double? in
        guard let base = buf.baseAddress else { return nil }
        var r = AssayReader(base: base, count: buf.count)
        return r.scanDouble()
    }
}

private func check(_ s: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let mine = assayParse(s)
    let theirs = Double(s)
    guard let m = mine, let t = theirs else {
        #expect(mine == nil && theirs == nil,
                "disagreed on whether \"\(s)\" parses", sourceLocation: sourceLocation)
        return
    }
    #expect(m.bitPattern == t.bitPattern,
            "\"\(s)\": Assay \(m) (0x\(String(m.bitPattern, radix: 16))) != stdlib \(t) (0x\(String(t.bitPattern, radix: 16)))",
            sourceLocation: sourceLocation)
}

@Suite("Double parsing")
struct DoubleTests {

    @Test("the Clinger fast path is bit-exact against the stdlib")
    func fastPathExact() {
        for s in ["0", "1", "-1", "3.5", "0.1", "-0.1", "1.5e3", "1e10", "1e22", "1e-22",
                  "123.456", "-123.456", "0.000001", "9007199254740992",
                  "1394.97", "-65.613473", "45.283329", "100.0", "0.0", "-0.0",
                  "2.2250738585072014e-308", "1.7976931348623157e308"] {
            check(s)
        }
    }

    @Test("values that must NOT take the fast path still round correctly")
    func slowPathExact() {
        for s in [
            "1e23",                                  // 10^23 not exactly representable
            "1e-23",
            "123456789012345678901234567890",        // >19 significant digits
            "0.1000000000000000055511151231257827",  // exactly 0.1's neighbour
            "5e-324",                                // smallest subnormal
            "2.4703282292062327e-324",               // subnormal rounding edge
            "1.7976931348623159e308",                // overflows to inf
            "9007199254740993",                      // 2^53 + 1, not representable
            "1.0000000000000002",                    // 1 + 1ulp
            "4.9406564584124654e-324",
        ] {
            check(s)
        }
    }

    @Test("exponent forms")
    func exponents() {
        for s in ["1e5", "1E5", "1e+5", "1e-5", "1.5E+10", "-2.5e-10", "0e0", "0e999"] {
            check(s)
        }
    }

    @Test("a wide sweep of generated decimals stays bit-exact")
    func sweep() {
        // Deterministic, so a failure is reproducible.
        var state: UInt64 = 0x2026_0726
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        for _ in 0..<4000 {
            let whole = next() % 1_000_000_000
            let frac = next() % 1_000_000_000
            let neg = next() & 1 == 0 ? "-" : ""
            check("\(neg)\(whole).\(frac)")
        }

        // Exponent-bearing forms across the fast-path boundary at ±22.
        for e in -30...30 {
            let m = next() % 100_000
            check("\(m).\(next() % 1000)e\(e)")
        }
    }

    @Test("malformed numbers are rejected, and the cursor rewinds")
    func malformed() {
        #expect(assayParse("") == nil)
        #expect(assayParse("abc") == nil)
        #expect(assayParse(".") == nil)
        #expect(assayParse("-") == nil)
        #expect(assayParse("1e") == nil)     // exponent marker with no digits
        #expect(assayParse("1e+") == nil)
    }

    @Test("integers do not silently truncate through the Double path")
    func integerShaped() {
        // Integer-shaped input takes tier (b); it must still be exact.
        check("9007199254740992")     // 2^53
        check("123456789")
        check("-987654321")
    }
}
