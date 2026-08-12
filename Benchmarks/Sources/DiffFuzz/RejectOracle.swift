// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The differential, run in the direction the original one could not see.
//
// WHY THIS FILE EXISTS. `runDifferential` reads the corpus, parses each file with both
// decoders, and compares the VALUES. It is a good test and it has a structural blind spot:
// every input is a document both parsers accept. It asks "did Assay refuse something
// Foundation takes?" and never the reverse — so an over-permissive parser is invisible to
// it, and the fuzzer beside it only asserts the absence of crashes and hangs.
//
// That blind spot hid nine real conformance bugs. Assay accepted raw control characters
// inside strings (RFC 8259 §7 requires them escaped) and a lax number grammar — `01`,
// `007`, `-01`, `.5`, `1.`, `1.e5` — where §6 is explicit that `int = zero /
// (digit1-9 *DIGIT)` and `frac = "." 1*DIGIT`. None of them crashed. None produced a wrong
// value for a valid document. They simply said yes where the specification says no, which
// is exactly the class of defect a one-directional differential cannot report.
//
// So this asks the other question: for a corpus of documents that are INVALID, or valid in
// a way that is easy to get wrong, do the two decoders agree about the verdict?
//
// JSONSerialization is the oracle rather than the judge. Where RFC 8259 leaves a choice to
// the implementation — duplicate keys, a byte-order mark, integers beyond Int64, nesting
// depth — the two are allowed to differ and the case is listed as `.implementationDefined`
// and reported without failing. Everything else is a hard requirement of the grammar, and
// a disagreement there is a bug in one of them.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayCore

enum Verdict {
    /// RFC 8259 requires this to be rejected. Both must refuse.
    case mustReject
    /// RFC 8259 requires this to be accepted. Both must take it.
    case mustAccept
    /// The RFC leaves it open. Reported, never failed.
    case implementationDefined
}

let rejectCorpus: [(String, String, Verdict)] = [

    // ---- §7, strings: control characters must be escaped -------------------
    ("raw tab in string",       "[\"a\u{09}b\"]", .mustReject),
    ("raw newline in string",   "[\"a\u{0A}b\"]", .mustReject),
    ("raw CR in string",        "[\"a\u{0D}b\"]", .mustReject),
    ("raw NUL in string",       "[\"a\u{00}b\"]", .mustReject),
    ("raw 0x1F in string",      "[\"a\u{1F}b\"]", .mustReject),
    ("raw 0x20 is legal",       "[\"a b\"]", .mustAccept),
    ("raw DEL is legal",        "[\"a\u{7F}b\"]", .mustAccept),
    ("control in a KEY",        "{\"a\u{09}b\": 1}", .mustReject),
    ("control after escape",    "[\"a\\n\u{09}b\"]", .mustReject),
    ("escaped control",         "[\"a\\tb\"]", .mustAccept),

    // ---- §7, strings: escapes ---------------------------------------------
    ("lone high surrogate",     "[\"\\uD800\"]", .mustReject),
    ("lone low surrogate",      "[\"\\uDC00\"]", .mustReject),
    ("reversed surrogates",     "[\"\\uDE00\\uD83D\"]", .mustReject),
    ("paired surrogates",       "[\"\\uD83D\\uDE00\"]", .mustAccept),
    ("bad escape letter",       "[\"\\x\"]", .mustReject),
    ("short \\u",               "[\"\\u12\"]", .mustReject),
    ("non-hex in \\u",          "[\"\\uZZZZ\"]", .mustReject),
    ("all legal escapes",       "[\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"]", .mustAccept),
    ("unterminated string",     "[\"abc]", .mustReject),

    // ---- §6, numbers: int = zero / ( digit1-9 *DIGIT ) ---------------------
    ("leading zero",            "[01]", .mustReject),
    ("multiple leading zeros",  "[007]", .mustReject),
    ("negative leading zero",   "[-01]", .mustReject),
    ("zero alone",              "[0]", .mustAccept),
    ("negative zero",           "[-0]", .mustAccept),
    ("zero then fraction",      "[0.5]", .mustAccept),
    ("zero then exponent",      "[0e0]", .mustAccept),
    ("two zeros",               "[00]", .mustReject),

    // ---- §6, numbers: frac = "." 1*DIGIT -----------------------------------
    ("no integer part",         "[.5]", .mustReject),
    ("no integer part, signed", "[-.5]", .mustReject),
    ("trailing decimal point",  "[1.]", .mustReject),
    ("point then exponent",     "[1.e5]", .mustReject),
    ("fraction is fine",        "[1.5]", .mustAccept),

    // ---- §6, numbers: exp = e [sign] 1*DIGIT -------------------------------
    ("exponent, no digits",     "[1e]", .mustReject),
    ("exponent sign, no digit", "[1e+]", .mustReject),
    ("double exponent",         "[1e2e3]", .mustReject),
    ("lone minus",              "[-]", .mustReject),
    ("plus sign",               "[+1]", .mustReject),
    ("capital E",               "[1E5]", .mustAccept),
    ("signed exponents",        "[1e+5, 1e-5]", .mustAccept),

    // ---- §6, numbers: not JSON at all --------------------------------------
    ("hex literal",             "[0x1]", .mustReject),
    ("octal-ish",               "[0o7]", .mustReject),
    ("Infinity",                "[Infinity]", .mustReject),
    ("-Infinity",               "[-Infinity]", .mustReject),
    ("NaN",                     "[NaN]", .mustReject),
    ("trailing garbage",        "[1abc]", .mustReject),

    // ---- §4/§5, structure --------------------------------------------------
    ("trailing comma, array",   "[1,]", .mustReject),
    ("trailing comma, object",  "{\"a\":1,}", .mustReject),
    ("leading comma",           "[,1]", .mustReject),
    ("double comma",            "[1,,2]", .mustReject),
    ("single quotes",           "['a']", .mustReject),
    ("unquoted key",            "{a:1}", .mustReject),
    ("missing colon",           "{\"a\" 1}", .mustReject),
    ("missing value",           "{\"a\":}", .mustReject),
    ("unclosed object",         "{\"a\":1", .mustReject),
    ("unclosed array",          "[1", .mustReject),
    ("mismatched brackets",     "[1}", .mustReject),
    ("bare comma",              ",", .mustReject),
    ("empty document",          "", .mustReject),
    ("whitespace only",         "   \n\t ", .mustReject),
    ("two documents",           "{}{}", .mustReject),
    ("JS comment",              "[1] // hi", .mustReject),
    ("block comment inside",    "[1 /* x */]", .mustReject),
    ("empty containers",        "[[],{},[{}]]", .mustAccept),
    ("empty key",               "{\"\":1}", .mustAccept),
    ("all whitespace forms",    "[\u{20}\u{09}\u{0A}\u{0D}1]", .mustAccept),

    // ---- §3, literals -------------------------------------------------------
    ("True capitalised",        "[True]", .mustReject),
    ("NULL capitalised",        "[NULL]", .mustReject),
    ("truncated literal",       "[tru]", .mustReject),
    ("literal with suffix",     "[truex]", .mustReject),
    ("the three literals",      "[true, false, null]", .mustAccept),

    // ---- left open by the RFC ----------------------------------------------
    ("duplicate keys",          "{\"a\":1,\"a\":2}", .implementationDefined),
    ("byte-order mark",         "\u{FEFF}{}", .implementationDefined),
    ("30-digit integer",        "[123456789012345678901234567890]", .implementationDefined),
    ("1e400 overflows Double",  "[1e400]", .implementationDefined),
    ("1e-400 underflows",       "[1e-400]", .implementationDefined),
    ("deep nesting",            String(repeating: "[", count: 200)
                                  + String(repeating: "]", count: 200), .implementationDefined),
    ("invalid UTF-8",           "\u{FFFD}", .implementationDefined),
]

/// Cases where JSONSerialization is KNOWN to diverge from RFC 8259, verified by hand.
/// Listed rather than silently tolerated so the oracle's own limits stay visible.
let knownFoundationLaxities: Set<String> = [
    // RFC 8259 §5: value *( value-separator value ). Foundation accepts a trailing one.
    "trailing comma, array",
    "trailing comma, object",
]

/// Numbers whose VALUE is easy to get wrong, checked against Foundation's answer.
///
/// Acceptance alone would never have found the worst bug in this file's history:
/// `scanInt64` returned nil on overflow WITHOUT rewinding the cursor, so the caller's
/// fallback to `scanDouble` began in the middle of the digits. `12345678901234567890`
/// decoded as **0.0** and `123456789012345678901234567890` as `1234567890.0` — accepted,
/// no issue reported, a different number. Only comparing values catches that.
let numberValueCorpus: [String] = [
    "0", "-0", "1", "-1", "1.5", "-1.5", "0.5", "1e5", "1e-5", "1E5", "1e+5",
    // The Int64 boundary, on both sides, where the overflow path is taken.
    "9223372036854775807", "9223372036854775808", "-9223372036854775808",
    "-9223372036854775809", "18446744073709551615", "18446744073709551616",
    // Past every integer type, into the fallback.
    "12345678901234567890", "123456789012345678901234567890",
    "1234567890123456789012345678901234567890",
    // 2^53, where exact integer representation in a Double ends.
    "9007199254740992", "9007199254740993",
    // Clinger's bound: exact powers of ten stop at 10^22.
    "1e22", "1e23", "1.7976931348623157e308", "5e-324", "2.2250738585072014e-308",
    // Long significands, which exercise the >19-digit path.
    "0.1234567890123456789012345", "3.141592653589793238462643383279",
    "1.000000000000000000000000001",
]

func assayAcceptsJSON(_ bytes: [UInt8]) -> Bool {
    var sink = IssueSink()
    let v = JSON.Value.decode(bytes, into: &sink)
    return sink.isValid && v != nil
}

func foundationAcceptsJSON(_ bytes: [UInt8]) -> Bool {
    (try? JSONSerialization.jsonObject(with: Data(bytes),
                                       options: [.fragmentsAllowed])) != nil
}

/// Every number decoded, compared bit-exactly against **the Swift stdlib**, with
/// JSONSerialization as a second opinion.
///
/// The stdlib is the primary oracle rather than Foundation, and the choice is not
/// arbitrary. `Double(String)` since swiftlang/swift#85797 is correctly rounded; Foundation
/// is not, and this differential proved it on its first run —
/// `0.1234567890123456789012345` decodes to `0.12345678901234568` (correct) in Assay and
/// `0.12345678901234573` through `NSNumber`. Treating Foundation as the judge would have
/// filed Assay's correct answer as the bug.
///
/// One honest caveat: for inputs that fall through to `slowDouble`, Assay *calls* the
/// stdlib, so the comparison there is vacuous by construction. It is not vacuous where it
/// matters — the tier-(a) Clinger path and the tier-(b) integer path are Assay's own
/// arithmetic, and those are exactly the literals with <= 19 significant digits and a
/// decimal exponent within +/-22. The corpus straddles both sides of that line.
func runNumberValueDifferential() -> Int {
    var checked = 0
    for literal in numberValueCorpus {
        let doc = "[\(literal)]"
        var sink = IssueSink()
        guard let v = JSON.Value.decode(Array(doc.utf8), into: &sink), sink.isValid,
              case .array(let items) = v, let first = items.first else {
            Failures.shared.fail("number \(literal): Assay refused a valid JSON number")
            continue
        }
        // An integer-shaped literal is checked against Int64, not against Double, and the
        // distinction is real rather than pedantic: `-0` decodes as the INTEGER zero, and
        // integer zero has no sign. Comparing it to `Double("-0")` reports a bug where the
        // value model is simply doing what a value model does.
        switch first {
        case .int(let i):
            guard let truth = Int64(literal) else {
                Failures.shared.fail("number \(literal): Assay made it an integer but the "
                    + "stdlib cannot; the corpus entry or the scanner is wrong")
                continue
            }
            if i != truth {
                Failures.shared.fail("number \(literal): Assay decoded \(i), correct is \(truth)")
            }
        case .double(let d):
            guard let truth = Double(literal) else {
                Failures.shared.fail("number \(literal): the stdlib cannot parse it either; "
                    + "the corpus entry is malformed")
                continue
            }
            if d.bitPattern != truth.bitPattern {
                Failures.shared.fail("number \(literal): Assay decoded \(d), "
                    + "correctly rounded is \(truth)")
            }
        default:
            Failures.shared.fail("number \(literal): decoded as \(first), not a number")
            continue
        }
        checked += 1

        // Foundation, reported and not enforced, so its divergences stay visible without
        // dictating the verdict. Only for genuinely fractional literals, where a Double is
        // the right yardstick for both sides.
        if literal.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }),
           let truth = Double(literal),
           let obj = try? JSONSerialization.jsonObject(with: Data(doc.utf8)),
           let arr = obj as? [Any], let n = arr.first as? NSNumber,
           n.doubleValue.bitPattern != truth.bitPattern {
            print("    (Foundation imprecise) \(literal): "
                  + "JSONSerialization gives \(n.doubleValue), correct is \(truth)")
        }
    }
    return checked
}

/// Returns the number of cases checked, and records a failure per disagreement.
func runRejectDifferential() -> Int {
    var checked = 0
    var openCases = 0

    for (name, doc, verdict) in rejectCorpus {
        let bytes = Array(doc.utf8)
        let assay = assayAcceptsJSON(bytes)

        switch verdict {
        case .mustReject:
            if assay {
                Failures.shared.fail("RFC 8259 requires rejecting \(name): "
                    + "\(doc.debugDescription) — Assay accepted it")
            }
            checked += 1
        case .mustAccept:
            if !assay {
                Failures.shared.fail("RFC 8259 requires accepting \(name): "
                    + "\(doc.debugDescription) — Assay refused it")
            }
            checked += 1
        case .implementationDefined:
            // Reported, never failed. Divergence here is a documented choice, and the
            // point of listing them is that the choice stays visible rather than drifting.
            openCases += 1
            let f = foundationAcceptsJSON(bytes)
            if assay != f {
                print("    (open) \(name): Assay=\(assay ? "accept" : "reject"), "
                      + "Foundation=\(f ? "accept" : "reject")")
            }
        }

        // Foundation as a second opinion on the table — but NOT as the judge. It has its
        // own documented laxities (it takes trailing commas, which RFC 8259 §5 forbids),
        // so a divergence is a prompt to check the table, not proof it is wrong. Known
        // ones are listed; a NEW one fails, because that is when the table is suspect.
        if verdict != .implementationDefined, !knownFoundationLaxities.contains(name) {
            let f = foundationAcceptsJSON(bytes)
            let expected = (verdict == .mustAccept)
            if f != expected {
                Failures.shared.fail("the reject-corpus table may be wrong about \(name): "
                    + "it says must\(expected ? "Accept" : "Reject") but JSONSerialization "
                    + "\(f ? "accepted" : "rejected") it")
            }
        }
    }
    return checked + openCases
}
