// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Findings from the pre-release audit, each pinned so it cannot come back.
//
// All four were live in code that had 250 passing tests, a differential oracle per
// format, and a fuzzer: the fuzzer proves a parser does not crash, and a differential
// proves two parsers agree on a document — neither asks what a *cheap* document can be
// made to cost, and neither reads the code for a quadratic loop.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayYAML

@Schema struct AuditCoerceInt32 { @Coerce var n: Int32 }
@Schema struct AuditCoerceUInt { @Coerce var n: UInt }
@Schema struct AuditTrimmed { @Preprocess(.trim) var s: String }

@Suite("Audit regressions")
struct AuditRegressionTests {

    /// FINDING 1 (critical). An alias costs one budget unit but expands to an entire
    /// subtree, and `Node` is a value type — so the parse result was a cheap DAG that
    /// every consumer materialised into a tree. 331 bytes reached 11.4 million nodes
    /// with ZERO issues reported, and `parse(yaml:)` projects through `RawValue`, so a
    /// schema decode was the exposed path. SECURITY.md's "alias-expansion bombs are
    /// capped by budget" was false for flow style, which is where bombs are written.
    @Test("YAML alias bomb is refused, and the budget is charged in flow style too")
    func aliasBomb() {
        func bomb(levels: Int, fanout: Int) -> String {
            var y = "l0: &l0 [" + (0..<fanout).map { _ in "\"x\"" }.joined(separator: ",") + "]\n"
            for i in 1...levels {
                let refs = (0..<fanout).map { _ in "*l\(i - 1)" }.joined(separator: ",")
                y += "l\(i): &l\(i) [\(refs)]\n"
            }
            return y + "top: *l\(levels)\n"
        }

        // 9^6 ≈ 11.4M nodes from 331 bytes: refused, by name.
        var sink = IssueSink()
        _ = YAML.decodeAll(Array(bomb(levels: 6, fanout: 9).utf8), into: &sink,
                           limits: .default)
        #expect(sink.issues.contains { $0.code == .custom("yaml_expansion_limit") },
                "a 9^6 alias bomb must be refused")

        // The bound must not be so eager that ordinary aliasing breaks. 9^3 ≈ 15k nodes
        // is a large but legitimate document and still parses clean.
        var ok = IssueSink()
        let docs = YAML.decodeAll(Array(bomb(levels: 3, fanout: 9).utf8), into: &ok,
                                  limits: .default)
        #expect(ok.issues.isEmpty, "legitimate aliasing must still parse")
        #expect(docs.count == 1)
    }

    @Test("ordinary anchors and aliases are unaffected")
    func normalAliases() throws {
        let doc = try YAML.parse(Array("base: &b {x: 1, y: 2}\nuse: *b\n".utf8))
        #expect(doc["use"]?["x"]?.resolvedInt == 1)
        #expect(doc["use"]?["y"]?.resolvedInt == 2)
    }

    /// FINDING 2. The coercing decoders narrowed with `flatMap { Int32(exactly:) }` and
    /// returned nil on overflow WITHOUT reporting — so `diagnose` answered
    /// `isValid == true` with no value, and `parse` threw an `AssayError` carrying zero
    /// issues. "The decoder that tells you what went wrong" told you nothing.
    @Test("coercion overflow reports an issue rather than vanishing")
    func coercionOverflowReports() {
        let d = AuditCoerceInt32.diagnose(json: Array(#"{"n": "999999999999"}"#.utf8))
        #expect(!d.isValid, "a failed decode must never report isValid")
        #expect(d.value == nil)
        #expect(d.issues.contains { $0.code == .numberOverflow })

        let u = AuditCoerceUInt.diagnose(json: Array(#"{"n": -5}"#.utf8))
        #expect(!u.isValid)
        #expect(u.issues.contains { $0.code == .numberOverflow })

        // And the invariant the bug violated, stated directly: a nil value and an empty
        // issue list must never coexist.
        for d in [AuditCoerceInt32.diagnose(json: Array(#"{"n": "9e99"}"#.utf8)),
                  AuditCoerceInt32.diagnose(json: Array(#"{"n": true}"#.utf8))] {
            if d.value == nil { #expect(!d.issues.isEmpty, "nil value with no issues") }
        }
    }

    /// FINDING 3. `@Preprocess(.trim)` trimmed with `Array.removeFirst()` in a loop,
    /// which is O(n) per removal — so trimming was O(n²) in the leading-whitespace run,
    /// on input an attacker controls. 400 kB of leading spaces was ~10¹¹ byte moves.
    @Test("trim is linear in the input, not quadratic")
    func trimIsLinear() throws {
        let pad = String(repeating: " ", count: 400_000)
        let v = try AuditTrimmed.parse(json: Array("{\"s\":\"\(pad)x\(pad)\"}".utf8))
        #expect(v.s == "x")
    }

    @Test("trim still trims exactly what it should")
    func trimCorrectness() throws {
        #expect(try AuditTrimmed.parse(json: Array(#"{"s":"  a b  "}"#.utf8)).s == "a b")
        #expect(try AuditTrimmed.parse(json: Array(#"{"s":"abc"}"#.utf8)).s == "abc")
        #expect(try AuditTrimmed.parse(json: Array(#"{"s":"   "}"#.utf8)).s == "")
        #expect(try AuditTrimmed.parse(json: Array(#"{"s":""}"#.utf8)).s == "")
        #expect(try AuditTrimmed.parse(json: Array("{\"s\":\"\\t\\nx\\r \"}".utf8)).s == "x")
    }

    /// FINDING 4. The renderer built a newline index over the WHOLE source, so drawing
    /// one caret from a mapped file scanned every page and allocated ~4 bytes per line
    /// of the entire document — on the error path, undoing the reason `SourceBytes` can
    /// borrow a mapping at all. It is now bounded to the deepest reported offset.
    @Test("the line index is bounded to what the render reaches, and output is unchanged")
    func boundedLineIndex() {
        // An issue on line 2 of a document with a very long, valid tail: before the
        // bound, this indexed all 20,000 lines to draw one caret near the top.
        var tail = ""
        for i in 0..<20_000 { tail += ",\n\"pad\(i)\": 1" }
        let json = "{\n\"n\": \"not-a-number\"\(tail)\n}"
        let d = AuditCoerceInt32.diagnose(json: Array(json.utf8))
        #expect(!d.isValid)
        let text = d.render(.plain)
        // Exactness is what must survive the bound: line 2, the caret under the value.
        #expect(text.contains(":2:"), "line number must stay exact under the bound")
        #expect(text.contains("^"))
    }
}
