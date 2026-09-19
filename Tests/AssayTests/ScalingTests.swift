// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayYAML
import AssayXML
import AssayTOML

//===----------------------------------------------------------------------===//
// SCALING, ON EVERY PLATFORM THE TEST SUITE RUNS ON.
//
// `Benchmarks/count.py scale` gates the log-log slope of cost against size EXACTLY, with
// Valgrind instruction counts, but only on Linux. Windows has no Valgrind and never will,
// and Windows is a supported platform. This is the portable half: the same question asked
// with a clock, which is only admissible because it is a RATIO taken inside one process.
// Machine speed cancels, and the bound is on the ratio, not on a time.
//
// One size is eight times the other. Linear cost gives ~8x, n log n ~9x and quadratic 64x.
// The bound is 8^1.33 = 16, which is wide enough that a contended CI runner does not trip
// it and narrow enough that nothing quadratic survives it. Each size is timed best-of-five,
// interleaved, because noise only ever ADDS time and interleaving spreads a slow phase over
// both sizes rather than one.
//
// Like AmplificationTests' ceilings, this is a blowup detector and must never be tightened
// into a performance gate: count.py is the instrument for "did it get slower".
//
// Every format decodes through its own hand-written parser and then the shared RawValue
// path, so a quadratic in any one of them shows up here, on the platform where it lives.
//===----------------------------------------------------------------------===//

import Dispatch

// `coerceScalars` because XML text is always a string: an XML `<n>0</n>` is an Int only by
// coercion, and without it every row would be an issue and the test would time the error path.
@Schema(coerceScalars: true, formats: .all) struct ScaleRow: Equatable {
    var name: String
    var n: Int
    var tags: [String]
}
@Schema(formats: .all) struct ScaleDoc: Equatable { var items: [ScaleRow] }

@Suite("Scaling — cost against size, portable")
struct ScalingTests {

    enum Format: String, CaseIterable { case json, yaml, xml, toml }

    /// `n` rows, each with a `valueLength`-byte name.
    static func document(_ f: Format, rows n: Int, valueLength: Int = 4) -> String {
        let v = String(repeating: "x", count: valueLength)
        switch f {
        case .json:
            return "{\"items\":[" + (0..<n).map {
                "{\"name\":\"\(v)\",\"n\":\($0),\"tags\":[\"a\",\"b\"]}" }
                .joined(separator: ",") + "]}"
        case .yaml:
            // Indentless, the way most real YAML is written. This fixture found that the
            // parser refused the form (fixed 2026-09-19, YAMLIndentlessSequenceTests).
            return "items:\n" + (0..<n).map {
                "- name: \(v)\n  n: \($0)\n  tags: [a, b]\n" }.joined()
        case .xml:
            return "<doc>" + (0..<n).map {
                "<items><name>\(v)</name><n>\($0)</n><tags>a</tags><tags>b</tags></items>" }
                .joined() + "</doc>"
        case .toml:
            return (0..<n).map {
                "[[items]]\nname = \"\(v)\"\nn = \($0)\ntags = [\"a\", \"b\"]\n" }.joined()
        }
    }

    static func decode(_ f: Format, _ text: String) throws -> ScaleDoc {
        switch f {
        case .json: return try ScaleDoc.parse(json: text)
        case .yaml: return try ScaleDoc.parse(yaml: text)
        case .xml: return try ScaleDoc.parse(xml: text)
        case .toml: return try ScaleDoc.parse(toml: text)
        }
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Best-of-five for each input, interleaved; returns large / small.
    static func ratio(_ small: String, _ large: String,
                      _ run: (String) throws -> Void) rethrows -> Double {
        var best = (s: UInt64.max, l: UInt64.max)
        for _ in 0..<5 {
            var t = now(); try run(small); best.s = min(best.s, now() - t)
            t = now(); try run(large); best.l = min(best.l, now() - t)
        }
        return Double(best.l) / Double(max(best.s, 1))
    }

    static let bound = 16.0

    @Test("rows: 8x the rows costs at most ~8x", arguments: Format.allCases)
    func rows(_ f: Format) throws {
        let small = Self.document(f, rows: 250), large = Self.document(f, rows: 2_000)
        // Correctness first: a fixture that fails to decode would time the error path.
        #expect(try Self.decode(f, small).items.count == 250)
        #expect(try Self.decode(f, large).items.count == 2_000)
        let r = try Self.ratio(small, large) { _ = try Self.decode(f, $0) }
        #expect(r < Self.bound, "\(f): 8x the rows cost \(r)x — suspect a quadratic path")
    }

    @Test("value length: 8x longer strings cost at most ~8x", arguments: Format.allCases)
    func valueLength(_ f: Format) throws {
        let small = Self.document(f, rows: 20, valueLength: 2_000)
        let large = Self.document(f, rows: 20, valueLength: 16_000)
        #expect(try Self.decode(f, large).items.first?.name.utf8.count == 16_000)
        let r = try Self.ratio(small, large) { _ = try Self.decode(f, $0) }
        #expect(r < Self.bound, "\(f): 8x longer values cost \(r)x — suspect a quadratic path")
    }
}
