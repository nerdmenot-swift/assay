// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// RFC 8259 conformance — the cases a one-directional differential cannot see.
//
// `DiffFuzz`'s original JSON differential parses every corpus file with both decoders and
// compares the VALUES. Every input is therefore a document both accept, so it asks "did
// Assay refuse something Foundation takes?" and never the reverse. The fuzzer beside it
// asserts only that nothing crashes or hangs.
//
// Nine conformance bugs lived in that blind spot: raw control characters inside strings
// (§7 requires them escaped) and a lax number grammar — `01`, `007`, `-01`, `.5`, `1.`,
// `1.e5` — against §6's `int = zero / (digit1-9 *DIGIT)` and `frac = "." 1*DIGIT`.
//
// Chasing those turned up something worse, which acceptance testing could not have found
// either: `scanInt64` returned nil on overflow WITHOUT rewinding the cursor, so the
// caller's fallback to `scanDouble` started in the middle of the digits. A 20-digit
// integer decoded as **0.0** and a 30-digit one as **1234567890.0** — no issue, no
// infinity, a different number. That is the bug in this file worth remembering.
//
// The exhaustive tables live in `Benchmarks/Sources/DiffFuzz/RejectOracle.swift`, which
// runs both decoders against a corpus of invalid documents and checks numbers bit-exactly
// against the stdlib. These are the same properties, pinned where `swift test` runs them.
//===----------------------------------------------------------------------===//

import Testing
import Assay
@testable import AssayCore

private func accepts(_ doc: String) -> Bool {
    var sink = IssueSink()
    let v = JSON.Value.decode(Array(doc.utf8), into: &sink)
    return sink.isValid && v != nil
}

private func number(_ literal: String) -> JSON.Value? {
    var sink = IssueSink()
    guard let v = JSON.Value.decode(Array("[\(literal)]".utf8), into: &sink), sink.isValid,
          case .array(let items) = v else { return nil }
    return items.first
}

@Suite("RFC 8259 §7 — strings")
struct StringConformanceTests {

    /// The single most common laxity in a hand-written JSON parser, and one comparison to
    /// refuse. A raw newline inside a string means the document is not JSON.
    @Test("a raw control character below 0x20 is refused", arguments: [
        "\u{00}", "\u{01}", "\u{08}", "\u{09}", "\u{0A}", "\u{0B}", "\u{0C}", "\u{0D}",
        "\u{1E}", "\u{1F}",
    ])
    func rawControlsRefused(_ c: String) {
        #expect(!accepts("[\"a\(c)b\"]"), "raw U+\(String(c.unicodeScalars.first!.value, radix: 16)) must be escaped")
        #expect(!accepts("{\"a\(c)b\": 1}"), "and in a key too")
    }

    @Test("0x20 and 0x7F are legal raw; escapes are legal")
    func legalRawBytes() {
        #expect(accepts("[\"a b\"]"))
        #expect(accepts("[\"a\u{7F}b\"]"), "DEL is not a C0 control")
        #expect(accepts("[\"a\\tb\"]"), "the same byte, escaped")
        #expect(accepts(#"["\"\\\/\b\f\n\r\t"]"#))
    }

    /// The escape path is a separate loop and had the same hole.
    @Test("a raw control AFTER an escape is refused too")
    func controlOnTheSlowPath() {
        #expect(!accepts("[\"a\\n\u{09}b\"]"))
    }

    @Test("surrogates: paired accepted, lone and reversed refused")
    func surrogates() {
        #expect(accepts(#"["😀"]"#))
        #expect(!accepts(#"["\uD800"]"#))
        #expect(!accepts(#"["\uDC00"]"#))
        #expect(!accepts(#"["\uDE00\uD83D"]"#))
    }
}

@Suite("RFC 8259 §6 — the number grammar")
struct NumberConformanceTests {

    /// `int = zero / ( digit1-9 *DIGIT )`. Accepting `01` silently reinterprets a
    /// zero-padded identifier as an integer.
    @Test("a leading zero is refused", arguments: ["01", "007", "-01", "00", "-00", "0123"])
    func leadingZeros(_ literal: String) {
        #expect(!accepts("[\(literal)]"))
        #expect(!accepts(literal), "and as a bare document")
    }

    @Test("a single zero, and zero with a fraction or exponent, are fine")
    func legalZeros() {
        for literal in ["0", "-0", "0.5", "-0.5", "0e0", "0E0", "0e+1"] {
            #expect(accepts("[\(literal)]"), "\(literal) is a number")
        }
    }

    /// `frac = "." 1*DIGIT` and the integer part is mandatory.
    @Test("a missing integer part or missing fraction digits is refused",
          arguments: [".5", "-.5", "1.", "-1.", "1.e5", "1.E5", "."])
    func fractionGrammar(_ literal: String) {
        #expect(!accepts("[\(literal)]"))
    }

    @Test("exponent must carry at least one digit",
          arguments: ["1e", "1E", "1e+", "1e-", "1e2e3", "-", "+1"])
    func exponentGrammar(_ literal: String) {
        #expect(!accepts("[\(literal)]"))
    }

    @Test("what is not JSON at all", arguments: [
        "0x1", "0o7", "Infinity", "-Infinity", "NaN", "1abc", "1_000",
    ])
    func notNumbers(_ literal: String) {
        #expect(!accepts("[\(literal)]"))
    }
}

@Suite("Integer overflow rewinds the cursor")
struct OverflowRewindTests {

    /// THE bug this file exists for. `scanInt64` overflowing without rewinding left the
    /// cursor mid-number, so the `scanDouble` fallback parsed whatever digits remained.
    /// Both of these were accepted, with no issue reported, as a different number.
    @Test("an integer past Int64 decodes as the right Double, not a fragment")
    func pastInt64() throws {
        let cases: [(String, Double)] = [
            ("12345678901234567890", 1.2345678901234567e19),
            ("123456789012345678901234567890", 1.2345678901234568e29),
            ("9223372036854775808", 9.223372036854776e18),
            ("-9223372036854775809", -9.223372036854776e18),
            ("18446744073709551616", 1.8446744073709552e19),
            ("1234567890123456789012345678901234567890", 1.2345678901234568e39),
        ]
        for (literal, expected) in cases {
            let v = try #require(number(literal), "\(literal) must decode")
            guard case .double(let d) = v else {
                Issue.record("\(literal) decoded as \(v), expected a double")
                continue
            }
            #expect(d == expected, "\(literal) decoded as \(d)")
            // The property, stated independently of the table: it must equal what the
            // correctly-rounded stdlib conversion gives.
            #expect(d.bitPattern == Double(literal)!.bitPattern)
        }
    }

    @Test("the Int64 boundary itself still decodes as an integer")
    func boundary() throws {
        for (literal, expected) in [("9223372036854775807", Int64.max),
                                    ("-9223372036854775808", Int64.min)] {
            let v = try #require(number(literal))
            guard case .int(let i) = v else {
                Issue.record("\(literal) decoded as \(v), expected an int")
                continue
            }
            #expect(i == expected)
        }
    }

    /// The same rewind matters for the schema path, which tries Int and falls back.
    @Test("a schema field typed Double takes an over-Int64 literal correctly")
    func schemaPath() throws {
        let v = try Measured.parse(json: #"{"value": 12345678901234567890}"#)
        #expect(v.value == 1.2345678901234567e19)
    }

    /// And a field typed Int reports rather than silently taking a fragment.
    @Test("a schema field typed Int reports an over-Int64 literal")
    func schemaPathInt() {
        let d = Counted.diagnose(json: #"{"value": 12345678901234567890}"#)
        #expect(!d.isValid)
        #expect(d.issues.allSatisfy { $0.code == .typeMismatch || $0.code == .numberOverflow })
    }
}

@Suite("What a structural skip does and does not check")
struct SkipContractTests {

    /// Pinned as a DECISION, not an accident. The skip validates a value's extent and not
    /// its contents, which is what makes the prefix path fast; the cost is that
    /// `T.parse(json:)` is not a whole-document validator. `JSON.Value.parse` is.
    @Test("a skipped value's contents are not validated", arguments: [
        "01", ".5", "1.", "1e", "NaN", "'x'", "undefined",
    ])
    func skippedContentsAreNotChecked(_ bad: String) {
        let doc = "{\"known\": 1, \"unknown\": \(bad)}"
        #expect(Skipper.diagnose(json: doc).isValid,
                "the schema path skips this value without reading it")
        #expect(!accepts(doc),
                "and JSON.Value, which reads everything, refuses it")
    }

    /// The extent IS checked, which is what keeps the document structurally sound.
    @Test("a skipped value's extent is validated", arguments: [
        "{\"known\": 1, \"unknown\": [1, 2",
        "{\"known\": 1, \"unknown\": \"unterminated}",
        "{\"known\": 1, \"unknown\": {\"a\": }",
    ])
    func extentIsChecked(_ doc: String) {
        #expect(!Skipper.diagnose(json: doc).isValid)
    }

    /// A `}` inside a skipped string must not close the object.
    @Test("string state is honoured while skipping")
    func stringStateHonoured() throws {
        let v = try Skipper.parse(json: #"{"unknown": "a}b", "known": 7}"#)
        #expect(v.known == 7)
    }
}

@Schema struct Measured: Equatable { var value: Double }
@Schema struct Counted: Equatable { var value: Int }
@Schema struct Skipper: Equatable { var known: Int }
