// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// ONE PROPERTY PER FIXTURE.
//
// Every shape here is the BASE with exactly one thing moved. That is the whole design: a
// number on its own says how fast one shape is, and two numbers that differ in exactly one
// property say WHY. The existing corpus cannot do this — `apimodel` differs from
// `short-strings` in field count, key length, value types, nesting and value width all at
// once, so when they disagree there is nothing to attribute it to.
//
// The base: 5 fields, short keys (≤15 bytes, so the key stays in the small-string form),
// short string values, flat, minified, no nulls, no unknown keys, every element valid.
//
// Each shape below names the property it moves and why that property is worth an axis.
// Several of them exist because CLAUDE.md makes an architectural claim about them that
// nothing measured:
//
//   * FIELD COUNT crosses the jump-table threshold. Experiment #1 found N ≥ 10 gives a real
//     arm64 jump table and below it a balanced search tree. Every benchmark in this
//     repository used a type with fewer than ten fields, so the table — the thing the
//     dispatch design is FOR — was never once exercised by a benchmark.
//   * KEY LENGTH crosses the 15-byte small-string boundary, which the honesty rules single
//     out ("no SSO-dependent claim without the length histogram").
//   * ESCAPE DENSITY is the memcpy/transform fork, "one of the largest in any decoder" per
//     Strings.swift, with a corpus shape but no gradient.
//   * WHITESPACE: the efficiency audit measured ~8% for a whitespace skipper on pretty
//     input and then had nowhere to put the number.
//   * ERROR DENSITY: the headline claim is that the error path is FASTER than throw-on-first.
//     That is a claim about a gradient and was measured at one point on it.
//===----------------------------------------------------------------------===//

import Foundation

let elementCount = 2_000

/// A fixture: the document bytes, and the task family that knows how to decode it.
struct Shape {
    let name: String
    let json: [UInt8]
    /// The property this shape moves off the base, for the printed legend.
    let moves: String
}

// MARK: - Builders

private func shortKey(_ i: Int) -> String { "f\(i)" }
private func longKey(_ i: Int) -> String { "a_rather_long_field_name_number_\(i)" }

private func quote(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        default: out.unicodeScalars.append(c)
        }
    }
    return out + "\""
}

/// `{"items":[ … ]}` — every fixture is this shape, so ns/element is comparable across all
/// of them and a document-level constant cannot masquerade as a per-element cost.
private func document(_ elements: [String], pretty: Bool = false) -> [UInt8] {
    if pretty {
        var s = "{\n  \"items\": [\n"
        s += elements.map { "    " + $0 }.joined(separator: ",\n")
        s += "\n  ]\n}\n"
        return Array(s.utf8)
    }
    return Array(("{\"items\":[" + elements.joined(separator: ",") + "]}").utf8)
}

private func stringElement(fields: Int, key: (Int) -> String, value: (Int) -> String) -> String {
    var parts: [String] = []
    parts.reserveCapacity(fields)
    for f in 0..<fields { parts.append("\(quote(key(f))):\(quote(value(f)))") }
    return "{" + parts.joined(separator: ",") + "}"
}

// MARK: - The shapes

func allShapes() -> [Shape] {
    var out: [Shape] = []
    func add(_ name: String, _ moves: String, _ bytes: [UInt8]) {
        out.append(Shape(name: name, json: bytes, moves: moves))
    }

    let n = elementCount
    let shortValue: (Int) -> String = { "v\($0)" }
    let longValue: (Int) -> String = { _ in String(repeating: "x", count: 40) }

    // ---- the base ----
    add("base", "—", document((0..<n).map { _ in
        stringElement(fields: 5, key: shortKey, value: shortValue) }))

    // ---- field count ----
    //
    // 2 and 20 only. There WAS a `fields-100` here and it was a lie: `@Schema` accepts at
    // most 64 fields, so the shape fell through to the 20-field type and measured "20
    // decoded plus 80 structurally skipped" while calling itself a hundred-field decode.
    // It produced two convincing anomalies — a non-monotonic per-field cost and a skip path
    // that seemed to scale backwards — and both dissolved the moment the type was checked.
    // The axis has a proper home now in `AssayBench fieldsweep`, where key width is held
    // constant and every count is inside the real ceiling.
    for fields in [2, 20] {
        add("fields-\(fields)", "field count \(fields)", document((0..<n).map { _ in
            stringElement(fields: fields, key: shortKey, value: shortValue) }))
    }

    // ---- key length: the small-string boundary ----
    add("keys-long", "key length > 15 bytes", document((0..<n).map { _ in
        stringElement(fields: 5, key: longKey, value: shortValue) }))

    // ---- value width: the same boundary on the value side ----
    add("values-long", "value length 40 bytes", document((0..<n).map { _ in
        stringElement(fields: 5, key: shortKey, value: longValue) }))

    // ---- value type ----
    add("values-int", "Int64 values", document((0..<n).map { i in
        "{" + (0..<5).map { "\(quote(shortKey($0))):\(i &* 7 &+ $0)" }.joined(separator: ",") + "}" }))
    add("values-double", "Double values", document((0..<n).map { i in
        "{" + (0..<5).map { "\(quote(shortKey($0))):\(Double(i) + Double($0) * 0.25)" }.joined(separator: ",") + "}" }))
    add("values-bool", "Bool values", document((0..<n).map { i in
        "{" + (0..<5).map { "\(quote(shortKey($0))):\((i + $0) % 2 == 0)" }.joined(separator: ",") + "}" }))
    add("values-date", "ISO-8601 Date values", document((0..<n).map { i in
        "{" + (0..<5).map {
            "\(quote(shortKey($0))):\"2026-09-\(String(format: "%02d", 1 + (i + $0) % 28))T12:34:56Z\""
        }.joined(separator: ",") + "}" }))

    // ---- escape density: the memcpy/transform fork ----
    //
    // THE TWO VALUES ARE THE SAME LENGTH ON PURPOSE. The first version of this fixture used
    // "v0" for the plain case and "line\\nbreak0" for the escaped one, which moves value
    // width as well as escape presence — so the +66% it reported was partly the escape fork
    // and partly forty more bytes per element, with no way to tell how much of each. That
    // is precisely the mistake this whole matrix exists to make impossible, and it survived
    // one review because the two strings look similar rather than because they are.
    // 0% is included so the axis is self-contained: comparing against `base` would drag
    // value width back in, since base values are two bytes and these are nine.
    for pct in [0, 10, 100] {
        add("escapes-\(pct)", "\(pct)% of values carry an escape", document((0..<n).map { i in
            let escaped = pct == 100 || (i * 100 / n) < pct
            return stringElement(fields: 5, key: shortKey,
                                 value: { escaped ? "abcd\\nefgh\($0)" : "abcd_efgh\($0)" })
        }))
    }

    // ---- shape: nesting and arrays ----
    add("nested-3", "one nested object, 3 deep", document((0..<n).map { _ in
        "{\"f0\":\"v0\",\"f1\":\"v1\",\"f2\":\"v2\",\"f3\":\"v3\","
        + "\"inner\":{\"g0\":\"w0\",\"inner\":{\"h0\":\"z0\"}}}" }))
    add("array-10", "one array field of 10 strings", document((0..<n).map { _ in
        "{\"f0\":\"v0\",\"f1\":\"v1\",\"f2\":\"v2\",\"f3\":\"v3\","
        + "\"tags\":[" + (0..<10).map { "\"t\($0)\"" }.joined(separator: ",") + "]}" }))

    // ---- absence: the five presence states meet the wire here ----
    add("optional-absent", "5 optional fields, all absent", document((0..<n).map { _ in "{}" }))
    add("optional-null", "5 optional fields, all null", document((0..<n).map { _ in
        "{" + (0..<5).map { "\(quote(shortKey($0))):null" }.joined(separator: ",") + "}" }))

    // ---- unknown keys: the structural skip ----
    add("unknown-5", "5 unknown keys beside 5 known", document((0..<n).map { _ in
        "{" + (0..<5).map { "\(quote(shortKey($0))):\(quote("v\($0)"))" }.joined(separator: ",")
        + "," + (0..<5).map { "\(quote("u\($0)")):\(quote("w\($0)"))" }.joined(separator: ",") + "}" }))

    // ---- whitespace ----
    add("pretty", "pretty-printed, not minified", document((0..<n).map { _ in
        stringElement(fields: 5, key: shortKey, value: shortValue) }, pretty: true))

    // ---- error density: the claim is that this path is FAST ----
    for pct in [1, 10, 100] {
        add("errors-\(pct)", "\(pct)% of elements have a type error", document((0..<n).map { i in
            let bad = (i * 100 / n) < pct || pct == 100
            if bad {
                // f0 arrives as a number where a String is declared: one issue per element,
                // and the decoder must resynchronise and carry on.
                return "{\"f0\":123," + (1..<5).map {
                    "\(quote(shortKey($0))):\(quote("v\($0)"))" }.joined(separator: ",") + "}"
            }
            return stringElement(fields: 5, key: shortKey, value: shortValue)
        }))
    }

    return out
}

// MARK: - Scaling axes
//
// A shape is one point. An AXIS is one property swept over four sizes, with everything else
// held still, so the log-log slope of cost against size says whether a verb is linear in that
// property — the question no single-size benchmark can answer, and the one the O(n²) `.trim`
// and the Character-by-Character namespace lookup both got wrong without any benchmark
// noticing. `Benchmarks/count.py scale` measures each point with Valgrind and gates the slope.
//
// Each axis borrows an existing shape's NAME for dispatch, because the decode type is chosen
// by shape name (`Tasks.swift`), and a sweep must change the size and nothing else.

struct Axis {
    let name: String
    /// The shape whose decode type this axis's documents fit.
    let shape: String
    let tasks: [String]
    let sizes: [Int]
    let build: (Int) -> [UInt8]
}

func allAxes() -> [Axis] {
    let value: (Int) -> String = { "v\($0)" }
    // The size ladders are ×2 over three steps where the size is an element count (8× total,
    // enough to separate n from n log n from n²) and ×4 where it is a byte length, because a
    // byte-length cost is small per byte and needs the wider range to rise above the constant.
    let counts = [250, 500, 1_000, 2_000]
    let lengths = [16, 64, 256, 1_024]
    let fixed = 200
    return [
        Axis(name: "elements", shape: "base",
             tasks: ["struct", "diagnose", "skip", "value", "raw", "encode", "validate"],
             sizes: counts) { n in
            document((0..<n).map { _ in stringElement(fields: 5, key: shortKey, value: value) })
        },
        Axis(name: "value-length", shape: "base",
             tasks: ["struct", "skip", "value", "encode", "validate"], sizes: lengths) { len in
            document((0..<fixed).map { _ in
                stringElement(fields: 5, key: shortKey) { _ in String(repeating: "x", count: len) } })
        },
        // Escaped values take the slow path, which has its own buffer and its own loop.
        Axis(name: "escaped-length", shape: "escapes-100", tasks: ["struct", "value"],
             sizes: lengths) { len in
            let v = String(repeating: "ab\n", count: max(1, len / 3))
            return document((0..<fixed).map { _ in
                stringElement(fields: 5, key: shortKey) { _ in v } })
        },
        // Undeclared keys: the structural skip must be linear in what it skips.
        // Escaped strings × element count. The axis above holds the document small, so it
        // could not see what this one exists for: until 2026-09-19 every escaped string
        // reserved the REST OF THE DOCUMENT (masked to 16 bits) as its unescape buffer, so
        // heap per call grew with elements × document size. Sizes stay under 64 kB, where
        // the mask cannot wrap and hide it.
        Axis(name: "escaped-elements", shape: "escapes-100", tasks: ["struct", "skip", "value"],
             sizes: [50, 100, 200, 400]) { n in
            document((0..<n).map { i in
                stringElement(fields: 5, key: shortKey) { _ in "line\nbreak\(i)" } })
        },
        Axis(name: "unknown-key-length", shape: "unknown-5", tasks: ["struct", "skip", "value"],
             sizes: lengths) { len in
            document((0..<fixed).map { _ in
                "{" + (0..<5).map { "\(quote(shortKey($0))):\(quote("v\($0)"))" }
                    .joined(separator: ",") + ","
                + (0..<5).map { "\(quote("u\($0)" + String(repeating: "k", count: len))):\"w\"" }
                    .joined(separator: ",") + "}" })
        },
        Axis(name: "unknown-key-count", shape: "unknown-5", tasks: ["struct", "skip"],
             sizes: [5, 10, 20, 40]) { k in
            document((0..<fixed).map { _ in
                "{" + (0..<5).map { "\(quote(shortKey($0))):\(quote("v\($0)"))" }
                    .joined(separator: ",") + ","
                + (0..<k).map { "\(quote("u\($0)")):\"w\"" }.joined(separator: ",") + "}" })
        },
        Axis(name: "array-length", shape: "array-10", tasks: ["struct", "value", "raw"],
             sizes: [10, 40, 160, 640]) { len in
            document((0..<fixed).map { _ in
                "{\"f0\":\"v0\",\"f1\":\"v1\",\"f2\":\"v2\",\"f3\":\"v3\",\"tags\":["
                + (0..<len).map { "\"t\($0)\"" }.joined(separator: ",") + "]}" })
        },
        // Depth stays under `Limits.maxDepth` (64) with the two wrapping levels.
        Axis(name: "depth", shape: "base", tasks: ["value", "raw"], sizes: [7, 14, 28, 56]) { d in
            document([String(repeating: "[", count: d) + "1" + String(repeating: "]", count: d)])
        },
        // One wide object: the generic tree's own per-member cost, with no struct to help.
        Axis(name: "object-width", shape: "base", tasks: ["value", "raw"], sizes: counts) { n in
            document(["{" + (0..<n).map { "\"k\($0)\":\($0)" }.joined(separator: ",") + "}"])
        },
        // Every element carries a type error. Past `maxIssues` the sink stops keeping them,
        // and the decode must stay linear on both sides of that line.
        Axis(name: "issues", shape: "errors-100", tasks: ["diagnose", "value"], sizes: counts) { n in
            document((0..<n).map { _ in
                "{\"f0\":123," + (1..<5).map { "\(quote(shortKey($0))):\(quote("v\($0)"))" }
                    .joined(separator: ",") + "}" })
        },
    ]
}
