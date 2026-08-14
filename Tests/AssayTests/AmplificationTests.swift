// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The amplification gate: what does a CHEAP input cost?
//
// This suite exists because of a specific failure. A YAML alias bomb — 331 bytes
// reaching 11.4 million nodes with no issue reported — survived 250 passing tests, a
// differential oracle for every format, and a deterministic fuzzer. None of those could
// have caught it, and the reason is worth stating precisely rather than treating the bug
// as bad luck:
//
//   * A FUZZER proves a parser does not crash or hang on malformed input. The bomb
//     crashed nothing. It parsed perfectly.
//   * A DIFFERENTIAL proves two parsers agree on a document. libyaml agrees with Assay
//     about what the bomb means — both are correct. Agreeing on an answer says nothing
//     about what computing it costs.
//   * UNIT TESTS assert on results. The result was right.
//
// The missing question is the one every resource-exhaustion vulnerability answers wrong:
// **how much output can a small input buy?** That ratio is what this file bounds.
//
// GATING ON A RATIO, NOT ON A CLOCK. `CLAUDE.md` forbids gating CI on wall clock, and
// that rule is right — wall clock varies by machine and turns CI into a flake generator.
// So the assertions here are on *deterministic* quantities: nodes materialised, bytes
// produced, issues collected. Those are identical on every machine and every run.
//
// The one exception is the quadratic class, where the output is small and only the *work*
// explodes (the O(n^2) `.trim` bug this audit also found). No output metric can see that.
// For those, there is a deliberately absurd ceiling — seconds, where the correct answer is
// milliseconds. That is not a performance gate and must never be tightened into one: it is
// a blowup detector, sized so that a correct implementation can be 100x slower than
// expected on the world's most contended CI runner and still pass, while a quadratic one
// fails by orders of magnitude.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayYAML
import AssayXML

/// How many values a parsed tree actually contains, which is what a bomb inflates.
private func nodeCount(_ v: RawValue) -> Int {
    switch v {
    case .sequence(let xs): return 1 + xs.reduce(0) { $0 + nodeCount($1) }
    case .mapping(let ms): return 1 + ms.reduce(0) { $0 + nodeCount($1.value) }
    default: return 1
    }
}

private func nodeCount(_ v: JSON.Value) -> Int {
    switch v {
    case .array(let xs): return 1 + xs.reduce(0) { $0 + nodeCount($1) }
    case .object(let ms): return 1 + ms.reduce(0) { $0 + nodeCount($1.value) }
    default: return 1
    }
}

private func nodeCount(_ e: XML.Element) -> Int {
    1 + e.attributes.count + e.children.reduce(0) { acc, child in
        switch child {
        case .element(let sub): return acc + nodeCount(sub)
        default: return acc + 1
        }
    }
}

/// Every amplification case: a name, the bytes, and what it is allowed to cost.
///
/// `maxNodesPerInputByte` is the whole point. A well-behaved document produces output
/// roughly proportional to its input — a few nodes per byte at the very most, since a
/// node needs several bytes to describe. A bomb produces thousands or millions per byte.
/// The bound is generous (32) precisely so it never argues about parser detail: nothing
/// legitimate approaches it, and nothing exponential survives it.
private let maxNodesPerInputByte = 32

@Suite("Amplification — what a cheap input is allowed to cost")
struct AmplificationTests {

    // MARK: YAML

    /// Nested aliases: the exponential class. Each level references the previous N times.
    static func aliasBomb(levels: Int, fanout: Int) -> String {
        var y = "l0: &l0 [" + (0..<fanout).map { _ in "\"x\"" }.joined(separator: ",") + "]\n"
        for i in 1...levels {
            let refs = (0..<fanout).map { _ in "*l\(i - 1)" }.joined(separator: ",")
            y += "l\(i): &l\(i) [\(refs)]\n"
        }
        return y + "top: *l\(levels)\n"
    }

    @Test("YAML alias bombs stay bounded", arguments: [
        (6, 9), (8, 9), (12, 4), (20, 3), (40, 2),
    ])
    func yamlAliasBombs(_ levels: Int, _ fanout: Int) {
        let text = Self.aliasBomb(levels: levels, fanout: fanout)
        let bytes = Array(text.utf8)
        var sink = IssueSink()
        let docs = YAML.decodeAll(bytes, into: &sink, limits: .default)

        // Either refused, or produced something proportionate. Never both quiet and huge.
        let produced = docs.reduce(0) { $0 + (RawValue($1).map(nodeCount) ?? 1) }
        let budget = bytes.count * maxNodesPerInputByte
        #expect(produced <= budget,
                "\(levels)x\(fanout): \(bytes.count) bytes produced \(produced) nodes (budget \(budget)); issues=\(sink.issues.count)")
    }

    /// Linear alias repetition — the same anchor referenced many times at one level.
    /// Not exponential, but the classic "&a repeated ten thousand times" shape, and the
    /// reason the budget must bound TOTAL expansion rather than nesting depth.
    @Test("YAML repeated aliases stay bounded")
    func yamlRepeatedAliases() {
        let wide = (0..<400).map { _ in "*a" }.joined(separator: ",")
        let text = "a: &a [" + (0..<200).map { _ in "\"xxxxxxxx\"" }.joined(separator: ",")
            + "]\nb: [\(wide)]\n"
        let bytes = Array(text.utf8)
        var sink = IssueSink()
        let docs = YAML.decodeAll(bytes, into: &sink, limits: .default)
        let produced = docs.reduce(0) { $0 + (RawValue($1).map(nodeCount) ?? 1) }
        #expect(produced <= bytes.count * maxNodesPerInputByte,
                "\(bytes.count) bytes produced \(produced) nodes")
    }

    @Test("YAML deep nesting is refused rather than recursed")
    func yamlDeepNesting() {
        for text in [String(repeating: "[", count: 5_000),
                     String(repeating: "- ", count: 5_000),
                     String(repeating: "{a: ", count: 5_000)] {
            var sink = IssueSink()
            _ = YAML.decodeAll(Array(text.utf8), into: &sink, limits: .default)
            #expect(!sink.issues.isEmpty, "deep nesting must report, not recurse to a trap")
        }
    }

    // MARK: XML

    @Test("XML billion laughs stays bounded")
    func xmlBillionLaughs() {
        var doc = "<!DOCTYPE lolz [\n<!ENTITY lol \"lololololol\">\n"
        for i in 1...8 {
            let prev = i == 1 ? "lol" : "lol\(i - 1)"
            doc += "<!ENTITY lol\(i) \"" + (0..<10).map { _ in "&\(prev);" }.joined() + "\">\n"
        }
        doc += "]><lolz>&lol8;&lol8;&lol8;</lolz>"
        let bytes = Array(doc.utf8)

        var sink = IssueSink()
        let parsed = XML.decode(bytes, into: &sink, limits: .default)
        let producedBytes = parsed.map { $0.root.text.utf8.count } ?? 0
        // Output text must not dwarf the document that asked for it.
        #expect(producedBytes <= bytes.count * 256,
                "\(bytes.count) bytes produced \(producedBytes) bytes of text")
    }

    @Test("XML deep nesting and wide attribute lists stay bounded")
    func xmlStructural() {
        var sink = IssueSink()
        let deep = String(repeating: "<a>", count: 5_000)
        _ = XML.decode(Array(deep.utf8), into: &sink, limits: .default)
        #expect(!sink.issues.isEmpty, "unterminated deep nesting must report")

        // Many siblings: legitimate, and must stay proportionate.
        let wide = "<r>" + (0..<5_000).map { "<c\($0)/>" }.joined() + "</r>"
        let wb = Array(wide.utf8)
        var s2 = IssueSink()
        if let d = XML.decode(wb, into: &s2, limits: .default) {
            #expect(nodeCount(d.root) <= wb.count * maxNodesPerInputByte)
        }
    }

    // MARK: JSON

    @Test("JSON deep nesting is refused at the configured depth")
    func jsonDeepNesting() {
        let deep = String(repeating: "[", count: 10_000)
        var sink = IssueSink()
        _ = JSON.Value.decode(Array(deep.utf8), into: &sink, limits: .default)
        #expect(sink.issues.contains { $0.code == .depthExceeded || $0.code == .malformedDocument })
    }

    @Test("JSON output stays proportionate to input")
    func jsonProportionate() {
        let doc = "[" + (0..<5_000).map { _ in "0" }.joined(separator: ",") + "]"
        let bytes = Array(doc.utf8)
        var sink = IssueSink()
        guard let v = JSON.Value.decode(bytes, into: &sink, limits: .default) else { return }
        #expect(nodeCount(v) <= bytes.count * maxNodesPerInputByte)
    }

    @Test("issue collection is capped, and says when it capped")
    func issuesAreCapped() {
        // A large array of type-mismatched values: every element is an error.
        let doc = "{\"ns\":[" + (0..<20_000).map { _ in "\"x\"" }.joined(separator: ",") + "]}"
        var sink = IssueSink(limits: Limits(maxIssues: 50, maxDepth: 64, maxBytes: 1 << 20))
        _ = JSON.Value.decode(Array(doc.utf8), into: &sink, limits: .default)
        #expect(sink.issues.count <= 50, "issue collection must respect maxIssues")
    }

    // MARK: The quadratic class — a blowup detector, NOT a performance gate
    //
    // Read the file header before touching these numbers. The ceilings are absurd on
    // purpose: a correct implementation finishes in single-digit milliseconds, so a
    // hundredfold slowdown on a contended runner still passes, while an O(n^2) regression
    // misses by three orders of magnitude and fails everywhere.

    @Test("whitespace-heavy preprocessing is linear")
    func preprocessIsLinear() throws {
        let pad = String(repeating: " ", count: 300_000)
        let json = "{\"s\":\"\(pad)x\(pad)\"}"
        let start = DispatchTime.now().uptimeNanoseconds
        let v = try AmpTrimmed.parse(json: Array(json.utf8))
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        #expect(v.s == "x")
        #expect(seconds < 5.0,
                "600 kB of whitespace took \(seconds)s — that is quadratic, not slow")
    }

    @Test("long strings, keys and escapes stay linear")
    func longInputsAreLinear() {
        let cases = [
            "{\"s\":\"" + String(repeating: "a", count: 400_000) + "\"}",
            "{\"s\":\"" + String(repeating: "\\n", count: 200_000) + "\"}",
            "{\"" + String(repeating: "k", count: 200_000) + "\":1}",
            "[" + String(repeating: "1,", count: 200_000) + "1]",
        ]
        for doc in cases {
            let bytes = Array(doc.utf8)
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = IssueSink()
            _ = JSON.Value.decode(bytes, into: &sink, limits: .default)
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            #expect(seconds < 5.0,
                    "\(bytes.count) bytes took \(seconds)s — suspect a quadratic path")
        }
    }

    @Test("unknown-key did-you-mean does not blow up on many long keys")
    func didYouMeanIsBounded() {
        // .warn materialises every unknown key and runs an edit-distance search per key.
        let doc = "{" + (0..<2_000).map { "\"unknown_key_\($0)\":1" }.joined(separator: ",") + "}"
        let start = DispatchTime.now().uptimeNanoseconds
        _ = AmpWarned.diagnose(json: Array(doc.utf8))
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        #expect(seconds < 5.0, "2,000 unknown keys took \(seconds)s")
    }
}

@Schema struct AmpTrimmed { @Preprocess(.trim) var s: String }
@Schema(unknownKeys: .warn) struct AmpWarned { var known: Int = 0 }

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Minimal monotonic clock, so this file does not import Foundation — the test target
/// deliberately does not (swift-testing's Foundation overlay carries a macOS 13 floor).
private enum DispatchTime {
    struct Instant { var uptimeNanoseconds: UInt64 }
    static func now() -> Instant {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Instant(uptimeNanoseconds: UInt64(ts.tv_sec) * 1_000_000_000
                       + UInt64(ts.tv_nsec))
    }
}

// MARK: - XML entity expansion
//
// Nested entities were not re-expanded until 2026-08-14, so `<!ENTITY b "&a;">` yielded the
// literal text `&a;`. That was two bugs wearing one coat. The obvious one is the wrong
// value. The subtler one is that the file's own header claimed to "cap internal entity
// expansion (billion laughs)" while the cap was never what saved it — nothing expanded, so
// nothing needed capping, and a 290-byte bomb produced 30 harmless bytes for entirely the
// wrong reason.
//
// Fixing the expansion made the bound load-bearing for the first time, and it immediately
// failed: the classic billion-laughs document produced 1,000,000 bytes and passed, because
// the budget was a flat 8 MB and a megabyte is under eight. The absolute figure was never
// the right question. These tests bound the RATIO, as everything else in this file does.

@Suite("XML entity expansion")
struct XMLEntityTests {

    private func text(_ doc: String) throws -> String {
        try XML.parse(doc).root.text
    }

    @Test("a nested entity resolves rather than yielding its own source")
    func nestedResolves() throws {
        #expect(try text(#"<!DOCTYPE r [<!ENTITY a "world"><!ENTITY b "hello &a;">]><r>&b;</r>"#)
                == "hello world")
        #expect(try text("""
        <!DOCTYPE r [<!ENTITY a "x"><!ENTITY b "&a;&a;"><!ENTITY c "&b;&b;">]><r>&c;</r>
        """) == "xxxx")
    }

    @Test("predefined and numeric references still work inside a declared entity")
    func mixedReferences() throws {
        #expect(try text(#"<!DOCTYPE r [<!ENTITY e "a &amp; b">]><r>&e;</r>"#) == "a & b")
        #expect(try text(#"<!DOCTYPE r [<!ENTITY e "&#65;&#x42;">]><r>&e;</r>"#) == "AB")
    }

    /// XML 1.0 §4.1 forbids recursion outright, so this is a well-formedness error rather
    /// than something for the budget to absorb — and it must not recurse until the stack
    /// runs out first.
    @Test("a recursive entity is refused, directly and mutually")
    func recursionRefused() {
        for doc in [#"<!DOCTYPE r [<!ENTITY a "&a;">]><r>&a;</r>"#,
                    #"<!DOCTYPE r [<!ENTITY a "&b;"><!ENTITY b "&a;">]><r>&a;</r>"#,
                    #"<!DOCTYPE r [<!ENTITY a "&b;"><!ENTITY b "&c;"><!ENTITY c "&a;">]><r>&a;</r>"#] {
            var sink = IssueSink()
            let d = XML.decode(Array(doc.utf8), into: &sink)
            #expect(d == nil || !sink.isValid, "recursion must not be accepted")
            #expect(sink.issues.contains { $0.code == .custom("xml_recursive_entity") })
        }
    }

    /// The bound that matters, stated as a ratio. 290 bytes buying a megabyte is the attack
    /// whether or not a megabyte sounds small.
    @Test("billion laughs is refused on amplification, not on absolute size")
    func billionLaughs() {
        let doc = """
        <?xml version="1.0"?><!DOCTYPE l [\
        <!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">\
        <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;"><!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">\
        <!ENTITY e "&d;&d;&d;&d;&d;&d;&d;&d;&d;&d;"><!ENTITY f "&e;&e;&e;&e;&e;&e;&e;&e;&e;&e;">\
        ]><l>&f;</l>
        """
        #expect(doc.utf8.count < 400, "the input really is tiny")
        var sink = IssueSink()
        let d = XML.decode(Array(doc.utf8), into: &sink)
        #expect(d == nil || !sink.isValid)
        #expect(sink.issues.contains { $0.code == .custom("xml_entity_expansion_limit") })
    }

    /// The floor, so a small document may still use entities the way documents do.
    @Test("ordinary entity use is unaffected")
    func ordinaryUseIsFine() throws {
        let entity = #"<!ENTITY co "Example Corporation, Limited">"#
        let body = String(repeating: "<p>&co;</p>", count: 200)
        let doc = "<!DOCTYPE r [\(entity)]><r>\(body)</r>"
        let root = try XML.parse(doc).root
        #expect(root.childElements.count == 200)
        #expect(root.childElements[0].text == "Example Corporation, Limited")
    }

    @Test("an external entity is still refused outright — that is XXE")
    func xxeRefused() {
        var sink = IssueSink()
        _ = XML.decode(Array(#"""
        <!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/passwd">]><r>&x;</r>
        """#.utf8), into: &sink)
        #expect(!sink.isValid)
    }
}
