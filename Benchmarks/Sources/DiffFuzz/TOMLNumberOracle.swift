// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// EVERY NUMERIC LITERAL SHAPE, AGAINST toml++.
//
// Written 2026-09-13 for the decimal fast path in `scanNumberBody`. That path decides an
// integer without building an accumulator and hands a float's own source text to the
// stdlib, and it is allowed to DECLINE — on an underscore, an overflow, a leading zero, a
// missing digit — after which the general path re-derives the same input. The two must
// never disagree about what is valid or about what a literal is worth.
//
// The official `toml-test` suite has 710 cases across the whole language; this is ~4,000
// across the number grammar alone, which is the part the fast path touches. The generated
// set is deliberately heavy on the boundaries a hand-written scanner gets wrong: the
// separator rules (`1_0` yes, `1__0` no, `_1` no, `1_` no), leading zeros (`0` yes, `01`
// no, `0.5` yes), `Int64` limits in both directions, an exponent with every sign spelling,
// and the shapes that look numeric and are not (`1.`, `.5`, `1e`, `--1`, `0x_1`).
//
// Both sides must agree on the VERDICT and, when both accept, on the VALUE — which for a
// float means the exact bit pattern, because "close enough" is how a decoder ships a
// number that is not the number in the file.
//===----------------------------------------------------------------------===//

import Foundation

/// A float literal whose IEEE 754 binary64 value is not finite, or is zero (or subnormal)
/// for a literal that is not itself zero — `1e309`, `1e-400`, `0.5e-308`.
///
/// **toml++ REJECTS these and Assay accepts them, and that divergence PRE-DATES the fast
/// path** — verified by reverting the parser change and getting the identical 276
/// disagreements. It is reported below rather than gated, for three reasons:
///
///   * It is not a TOML question. Assay's JSON path accepts `1e309` too, and a struct
///     meaning different things depending on which format its bytes came from is the one
///     property this library refuses to have. Changing TOML alone would create exactly
///     that; changing both is a different piece of work on the hottest path in the library.
///   * Subnormals are valid binary64 values. toml++ goes through `strtod` and treats
///     `ERANGE` as an error, which catches underflow-to-subnormal as well as overflow —
///     that is arguably stricter than the specification, which says floats "should be
///     implemented as IEEE 754 binary64".
///   * The overflow half is the weaker of the two: a finite literal becoming `inf` is a
///     number read as a different number, which this codebase refuses elsewhere (the
///     128-bit plist integer). It is written down here as an open question rather than
///     quietly filtered.
func isKnownRangeDivergence(_ literal: String) -> Bool {
    guard let d = Double(literal) else { return false }
    if !d.isFinite { return true }
    if d == 0 || d.isSubnormal {
        // A literal that is GENUINELY zero is not a divergence — `0e0` is zero because its
        // mantissa is zero, not because it underflowed. Testing the whole literal for
        // non-zero characters got this wrong: the `e` made `0e0` look significant.
        let mantissa = literal.prefix { $0 != "e" && $0 != "E" }
        return Double(mantissa) != 0
    }
    return false
}

/// Every literal worth trying.
func tomlNumberLiterals() -> [String] {
    var literals: [String] = []

    // --- integers, plain ---
    literals += ["0", "-0", "+0", "1", "-1", "+1", "7", "42", "1000", "999999",
                 "2147483647", "2147483648", "-2147483648", "4294967295"]

    // --- Int64 boundaries, and one past each: the fast path accumulates as it reads and
    //     must hand over rather than wrap. ---
    literals += ["9223372036854775807", "9223372036854775806",
                 "-9223372036854775808", "-9223372036854775807",
                 "9223372036854775808", "-9223372036854775809",
                 "99999999999999999999", "-99999999999999999999",
                 String(repeating: "9", count: 40)]

    // --- leading zeros: `0` alone is an integer, `01` is not, `0.5` is a float ---
    literals += ["00", "01", "007", "-01", "+01", "0.5", "-0.5", "0.0", "00.0", "0e0", "00e0"]

    // --- separators, legal and not ---
    literals += ["1_0", "1_000", "1_000_000", "-1_0", "+1_0",
                 "1__0", "_1", "1_", "_", "1_.0", "1._0", "1_e2", "1e_2", "1e2_",
                 "0_1", "1_000_000_000_000"]

    // --- floats: fraction, exponent, both ---
    for mantissa in ["1", "0", "-1", "+1", "123", "-0"] {
        for frac in ["", ".0", ".5", ".25", ".000001", ".123456789012345"] {
            for exp in ["", "e0", "e1", "E1", "e+1", "e-1", "E+10", "E-10", "e308", "e-308",
                        "e309", "e-400"] {
                if frac.isEmpty && exp.isEmpty { continue }
                literals.append(mantissa + frac + exp)
            }
        }
    }

    // --- shapes that look numeric and are not ---
    literals += ["1.", ".5", "-.5", "1e", "1e+", "1e-", "1.e2", "1.2.3", "--1", "++1",
                 "+-1", "1-2", "1+2", "e1", "E1", ".e1", "1.2e", "1 2", "- 1", "+ 1"]

    // --- inf / nan, which precede the decimal path and must stay that way ---
    literals += ["inf", "+inf", "-inf", "nan", "+nan", "-nan", "infinity", "Inf", "NaN"]

    // --- radix prefixes: the fast path must not intercept these ---
    literals += ["0x1", "0xDEADBEEF", "0xdeadbeef", "0x_1", "0x1_2", "0x", "0o755", "0o8",
                 "0o", "0b1101", "0b102", "0b", "+0x1", "-0x1", "0X1", "0O7", "0B1",
                 "0x7FFFFFFFFFFFFFFF", "0x8000000000000000"]

    // --- long digit runs, where an accumulator's overflow check earns its keep ---
    for n in [18, 19, 20, 21, 30] {
        literals.append(String(repeating: "1", count: n))
        literals.append("-" + String(repeating: "1", count: n))
        literals.append(String(repeating: "9", count: n))
    }

    // --- deterministic random digit strings, signed and not, with and without a fraction ---
    var rng = SplitMix64(seed: 20260913)
    for _ in 0..<1_200 {
        let digits = 1 + rng.int(21)
        var t = ""
        for _ in 0..<digits { t.append(Character(UnicodeScalar(UInt8(0x30 + rng.int(10))))) }
        switch rng.int(4) {
        case 0: break
        case 1: t = "-" + t
        case 2: t += "." + String(1 + rng.int(999))
        default: t += "e" + (rng.int(2) == 0 ? "-" : "") + String(rng.int(40))
        }
        literals.append(t)
    }

    return literals
}

/// `x = <literal>`, and the same literal inside an array and an inline table, so the fast
/// path is exercised where the cursor is not at the start of a line.
func tomlNumberDocuments() -> [(name: String, text: String)] {
    let literals = tomlNumberLiterals()
    var out: [(name: String, text: String)] = []
    for (i, l) in literals.enumerated() where !isKnownRangeDivergence(l) {
        out.append(("n\(i)=\(l)", "x = \(l)\n"))
        out.append(("a\(i)=\(l)", "x = [\(l)]\n"))
        out.append(("t\(i)=\(l)", "x = { y = \(l) }\n"))
    }
    return out
}

/// The ones held out, so the count is visible rather than the set being silently smaller.
func tomlNumberHeldOut() -> [String] {
    tomlNumberLiterals().filter(isKnownRangeDivergence)
}

/// The arm. Reuses `runTOMLDifferential`, so the value comparison — sorted tables, exact
/// float bit patterns — is the same one the document corpus goes through.
func runTOMLNumberDifferential() -> YAMLOracleResult {
    let held = tomlNumberHeldOut()
    if !held.isEmpty {
        print("  \(held.count) literals held out as the documented range divergence "
              + "(overflow/underflow); see TOMLNumberOracle.swift. e.g. "
              + held.prefix(3).joined(separator: ", "))
    }
    return runTOMLDifferential(tomlNumberDocuments())
}
