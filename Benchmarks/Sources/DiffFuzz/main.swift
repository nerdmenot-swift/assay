// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Differential and fuzz testing.
//
// Two cheap, high-yield techniques the unit suite cannot cover:
//
//   DIFFERENTIAL — JSON.Value.parse against Foundation's JSONSerialization over every
//   positive corpus file, compared value-for-value. Two independent implementations
//   agreeing on 70+ documents is worth hundreds of hand-written assertions; the Double
//   suite already proved the technique against Double(String), bit-for-bit.
//
//   FUZZ — deterministic byte mutations and truncations of corpus seeds through all
//   three parsers, asserting exactly one thing: no crash, no hang. Every input either
//   parses or reports issues. Parsers that take untrusted input and have only ever seen
//   well-formed tests are parsers with undiscovered crashes.
//
// Deterministic by construction (SplitMix64, fixed seed): a failure here reproduces
// exactly, or it is not a finding. Exits nonzero on any failure, so CI can gate on it.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayCore
import AssayYAML
import AssayXML
import AssayTOML
import CorpusRender

// MARK: - Deterministic RNG (mirrors CorpusGen's)

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

// Top-level vars in main.swift are MainActor; a class keeps the helpers callable
// from the nonisolated functions without annotating everything.
final class Failures: @unchecked Sendable {
    static let shared = Failures()
    private(set) var count = 0
    func fail(_ message: String) {
        count += 1
        print("FAIL: \(message)")
    }
}
func fail(_ message: String) { Failures.shared.fail(message) }

// MARK: - Differential: JSON.Value vs JSONSerialization

func equivalent(_ mine: JSON.Value, _ theirs: Any) -> Bool {
    switch mine {
    case .null:
        return theirs is NSNull
    case .bool(let b):
        // NSNumber booleans need care: 1 as an NSNumber is not a Bool.
        guard let n = theirs as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            return false
        }
        return n.boolValue == b
    case .int(let i):
        guard let n = theirs as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
            return false
        }
        return n.int64Value == i
    case .double(let d):
        guard let n = theirs as? NSNumber else { return false }
        return n.doubleValue == d || (n.doubleValue.isNaN && d.isNaN)
    case .string(let s):
        return (theirs as? String) == s
    case .array(let items):
        guard let arr = theirs as? [Any], arr.count == items.count else { return false }
        return zip(items, arr).allSatisfy { equivalent($0, $1) }
    case .object(let members):
        guard let dict = theirs as? [String: Any], dict.count == members.count else {
            return false
        }
        return members.allSatisfy { m in
            guard let v = dict[m.key] else { return false }
            return equivalent(m.value, v)
        }
    }
}

func runDifferential(corpus: URL) throws -> Int {
    var checked = 0
    let files = try FileManager.default.contentsOfDirectory(at: corpus,
                                                            includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("neg-") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    for file in files {
        let data = try Data(contentsOf: file)
        let bytes = [UInt8](data)

        let mine: JSON.Value
        do {
            mine = try JSON.Value.parse(bytes)
        } catch {
            fail("\(file.lastPathComponent): Assay refused a file Foundation accepts")
            continue
        }
        let theirs = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if !equivalent(mine, theirs) {
            fail("\(file.lastPathComponent): value mismatch between Assay and Foundation")
        }
        checked += 1
    }
    return checked
}

// MARK: - Fuzz: mutations and truncations, no crashes allowed

func runFuzz(corpus: URL) throws -> Int {
    var iterations = 0
    var rng = SplitMix64(seed: 20260727)
    let limits = Limits(maxIssues: 20, maxDepth: 64, maxBytes: 1 << 20)

    // Seeds: one small file per shape, plus the negatives — already-broken documents
    // mutate into interesting shapes faster than valid ones do.
    let seeds = try FileManager.default.contentsOfDirectory(at: corpus,
                                                            includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.contains("-512b") || $0.lastPathComponent.hasPrefix("neg-") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    let yamlSeeds: [[UInt8]] = [
        Array("a: 1\nb:\n  - x\n  - {c: 2, d: [1,2]}\nanchor: &a v\nref: *a\n".utf8),
        Array("--- |\n  block\n---\n? [1,2]\n: complex\n".utf8),
    ]
    let xmlSeeds: [[UInt8]] = [
        Array("<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY e \"v\">]><r a='1'>&e;<b/><![CDATA[x]]></r>".utf8),
        Array("<r xmlns:n=\"u\"><n:a>t</n:a><!-- c --></r>".utf8),
    ]

    let tomlSeeds: [[UInt8]] = [
        Array("a = 1\nb.c = \"x\"\n[t]\nd = [1, {e = 2}, 1979-05-27T07:32:00Z]\n[[u]]\nf = 0x1f\n".utf8),
        Array("s = \"\"\"\nq\\\n  r\"\"\"\nl = '''\np'''\nn = -1_0.5e+3\nt = 07:32:00.5\n".utf8),
    ]

    func exercise(_ bytes: [UInt8]) {
        let trace = ProcessInfo.processInfo.environment["FUZZ_TRACE"] == "1"
        func mark(_ what: String) {
            guard trace else { return }
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            FileHandle.standardError.write(Data("\(what) \(hex)\n".utf8))
        }
        mark("JSON")
        var sink = IssueSink(limits: limits)
        _ = JSON.Value.decode(bytes, into: &sink, limits: limits)
        mark("YAML")
        var sink2 = IssueSink(limits: limits)
        _ = YAML.decodeAll(bytes, into: &sink2, limits: limits)
        mark("XML")
        var sink3 = IssueSink(limits: limits)
        _ = XML.decode(bytes, into: &sink3, limits: limits)
        mark("TOML")
        var sink4 = IssueSink(limits: limits)
        _ = TOML.decode(bytes, into: &sink4, limits: limits)
        // The generated code, on the same bytes. Four value models above and none of them
        // is where most of Assay's code comes from — `SchemaOracle.swift` says why, and
        // asserts three laws rather than settling for "it did not crash".
        mark("SCHEMA")
        for f in ["json", "yaml", "xml", "toml"] { fuzzSchema(bytes, f) }
    }

    for seed in seeds {
        let original = [UInt8](try Data(contentsOf: seed))

        // Byte mutations: flip, insert, delete, at deterministic positions.
        for _ in 0..<300 {
            var mutated = original
            switch rng.int(3) {
            case 0:
                if !mutated.isEmpty {
                    mutated[rng.int(mutated.count)] = UInt8(rng.int(256))
                }
            case 1:
                mutated.insert(UInt8(rng.int(256)), at: rng.int(mutated.count + 1))
            default:
                if !mutated.isEmpty { mutated.remove(at: rng.int(mutated.count)) }
            }
            exercise(mutated)
            iterations += 1
        }

        // Truncations at every prefix — the boundary-condition sweep.
        for cut in stride(from: 0, to: original.count, by: max(1, original.count / 64)) {
            exercise(Array(original[0..<cut]))
            iterations += 1
        }
    }

    // The schema seeds, mutated against their own format. These are the only inputs in
    // the whole arm that decode successfully often enough to exercise law 2.
    for (format, seed) in schemaSeeds {
        for _ in 0..<500 {
            var mutated = seed
            switch rng.int(3) {
            case 0:
                if !mutated.isEmpty { mutated[rng.int(mutated.count)] = UInt8(rng.int(256)) }
            case 1:
                mutated.insert(UInt8(rng.int(256)), at: rng.int(mutated.count + 1))
            default:
                if !mutated.isEmpty { mutated.remove(at: rng.int(mutated.count)) }
            }
            fuzzSchema(mutated, format)
            iterations += 1
        }
        // And the unmutated seed, which must decode — if it does not, the seed has rotted
        // and every mutation of it is testing the wrong thing.
        fuzzSchema(seed, format)
    }

    for seed in yamlSeeds + xmlSeeds + tomlSeeds {
        for _ in 0..<500 {
            var mutated = seed
            switch rng.int(3) {
            case 0:
                if !mutated.isEmpty { mutated[rng.int(mutated.count)] = UInt8(rng.int(256)) }
            case 1:
                mutated.insert(UInt8(rng.int(256)), at: rng.int(mutated.count + 1))
            default:
                if !mutated.isEmpty { mutated.remove(at: rng.int(mutated.count)) }
            }
            exercise(mutated)
            iterations += 1
        }
    }

    return iterations
}

// MARK: - Driver

// `DiffFuzz --probe <yaml|xml|toml|json> <string>` — the reducer used to shrink a fuzz
// finding to a minimal reproducer. Kept in the tool so a future finding is one command
// away from a minimal case.
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--probe" {
    let kind = CommandLine.arguments[2]
    let bytes = Array(CommandLine.arguments[3].utf8)
    let lim = Limits(maxIssues: 20, maxDepth: 64, maxBytes: 1 << 20)
    var s = IssueSink(limits: lim)
    switch kind {
    case "yaml": _ = YAML.decodeAll(bytes, into: &s, limits: lim)
    case "xml":  _ = XML.decode(bytes, into: &s, limits: lim)
    case "toml": _ = TOML.decode(bytes, into: &s, limits: lim)
    default:     _ = JSON.Value.decode(bytes, into: &s, limits: lim)
    }
    print("issues: \(s.issues.count)")
    exit(0)
}

let corpus = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()      // DiffFuzz
    .deletingLastPathComponent()      // Sources
    .deletingLastPathComponent()      // Benchmarks
    .appendingPathComponent("Corpus/files")

guard FileManager.default.fileExists(atPath: corpus.path) else {
    print("corpus missing — run: swift run -c release CorpusGen")
    exit(2)
}

// ---- The oracles, by name ----
//
// `DiffFuzz --list` names them; `DiffFuzz json plist-fuzz` runs two; no arguments runs
// every one in the order below. Until 2026-09-10 this file was fourteen oracles run
// unconditionally — the same shape `AssayBench/main.swift` had, fixed for the same reason:
// a parser change should cost the oracle for that parser, not all of them.

func report(_ title: String, _ oracle: String,
            agreed: Int, bothRejected: Int,
            assayOnly: [String], oracleOnly: [String],
            disagreed: [(name: String, detail: String)]) {
    print("")
    print("\(title) (oracle: \(oracle))")
    print("  agreed: \(agreed)   both rejected: \(bothRejected)")

    if !assayOnly.isEmpty {
        // Assay stricter. Not automatically a failure — it refuses XXE by construction,
        // and it implements a documented subset — so this is reported and not fatal.
        print("  Assay rejected, oracle accepted (\(assayOnly.count)): "
              + assayOnly.prefix(12).joined(separator: ", ")
              + (assayOnly.count > 12 ? ", ..." : ""))
    }
    if !oracleOnly.isEmpty {
        // The dangerous direction: Assay invented structure for input the oracle refused.
        print("  ** Assay ACCEPTED, oracle rejected (\(oracleOnly.count)): "
              + oracleOnly.prefix(12).joined(separator: ", ")
              + (oracleOnly.count > 12 ? ", ..." : ""))
        for n in oracleOnly { fail("\(title): Assay accepted \(n), \(oracle) rejected it") }
    }
    for d in disagreed {
        fail("\(title): \(d.name) — \(d.detail)")
    }
}


struct Oracle {
    let name: String
    let summary: String
    let run: () throws -> Void
}

// The JSON corpus is shared by several oracles; loaded once, on first use. A `let` at top
// level rather than a lazily-filled `var`: top-level state is MainActor-isolated and the
// oracle closures are not.
let jsonFiles: [(name: String, data: Data)] = {
    guard let all = try? FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
    else { return [] }
    var out: [(name: String, data: Data)] = []
    for url in all.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix("neg-") {
        guard let data = try? Data(contentsOf: url) else { continue }
        out.append((url.lastPathComponent, data))
    }
    return out
}()

let oracles: [Oracle] = [
    Oracle(name: "json", summary: "JSON.Value vs JSONSerialization over the corpus") {
        let checked = try runDifferential(corpus: corpus)
        print("JSON differential: \(checked) corpus files agree with JSONSerialization")
    },
    Oracle(name: "yaml", summary: "YAML vs Yams/libyaml, hand-written and generated; JSON as YAML") {
        let yamsHand = runYAMLDifferential(handWrittenYAML, oracleName: "Yams")
        report("YAML hand-written", "Yams/libyaml",
               agreed: yamsHand.agreed, bothRejected: yamsHand.bothRejected,
               assayOnly: yamsHand.assayOnlyRejected, oracleOnly: yamsHand.oracleOnlyRejected,
               disagreed: yamsHand.disagreed)
        var generatedYAML: [(name: String, text: String)] = []
        for (name, data) in jsonFiles {
            guard let value = try? JSON.Value.parse([UInt8](data)) else { continue }
            let rendered = renderYAML(RawValue(value))
            // A top-level scalar renders bare; mappings and sequences render with a
            // leading newline, which is legal YAML on its own.
            generatedYAML.append((name, rendered.hasPrefix("\n") ? String(rendered.dropFirst()) : rendered))
        }
        let yamsGen = runYAMLDifferential(generatedYAML, oracleName: "Yams")
        report("YAML generated (\(generatedYAML.count) documents)", "Yams/libyaml",
               agreed: yamsGen.agreed, bothRejected: yamsGen.bothRejected,
               assayOnly: yamsGen.assayOnlyRejected, oracleOnly: yamsGen.oracleOnlyRejected,
               disagreed: yamsGen.disagreed)
        // YAML 1.2 defines JSON as a strict subset, so the whole JSON corpus is a YAML
        // corpus and JSONSerialization is a second, independent oracle.
        let jsonAsYaml = runJSONAsYAML(jsonFiles)
        report("JSON-as-YAML (\(jsonFiles.count) files)", "JSONSerialization",
               agreed: jsonAsYaml.agreed, bothRejected: jsonAsYaml.bothRejected,
               assayOnly: jsonAsYaml.assayOnlyRejected, oracleOnly: jsonAsYaml.oracleOnlyRejected,
               disagreed: jsonAsYaml.disagreed)
    },
    Oracle(name: "xml", summary: "XML vs Foundation XMLParser, hand-written and generated") {
        let xmlHand = runXMLDifferential(handWrittenXML)
        report("XML hand-written", "Foundation XMLParser",
               agreed: xmlHand.agreed, bothRejected: xmlHand.bothRejected,
               assayOnly: xmlHand.assayOnlyRejected, oracleOnly: xmlHand.foundationOnlyRejected,
               disagreed: xmlHand.disagreed)
        var generatedXML: [(name: String, text: String)] = []
        for (name, data) in jsonFiles {
            guard let value = try? JSON.Value.parse([UInt8](data)) else { continue }
            generatedXML.append((name, renderXML(RawValue(value))))
        }
        let xmlGen = runXMLDifferential(generatedXML)
        report("XML generated (\(generatedXML.count) documents)", "Foundation XMLParser",
               agreed: xmlGen.agreed, bothRejected: xmlGen.bothRejected,
               assayOnly: xmlGen.assayOnlyRejected, oracleOnly: xmlGen.foundationOnlyRejected,
               disagreed: xmlGen.disagreed)
    },
    Oracle(name: "toml-numbers", summary: "~4,000 numeric literals vs toml++ — the decimal fast path") {
        let r = runTOMLNumberDifferential()
        report("TOML numbers", "toml++",
               agreed: r.agreed, bothRejected: r.bothRejected,
               assayOnly: r.assayOnlyRejected, oracleOnly: r.oracleOnlyRejected,
               disagreed: r.disagreed)
    },
    Oracle(name: "toml", summary: "TOML vs toml++ (TOMLKit), hand-written and generated; encode round trip") {
        let hand = runTOMLDifferential(handWrittenTOML)
        report("TOML hand-written", "toml++",
               agreed: hand.agreed, bothRejected: hand.bothRejected,
               assayOnly: hand.assayOnlyRejected, oracleOnly: hand.oracleOnlyRejected,
               disagreed: hand.disagreed)
        var generated: [(name: String, text: String)] = []
        for (name, data) in jsonFiles {
            guard let value = try? JSON.Value.parse([UInt8](data)),
                  let inline = renderTOML(RawValue(value)),
                  let sectioned = renderTOML(RawValue(value), sections: true) else { continue }
            generated.append((name, inline))
            generated.append((name + " [[sections]]", sectioned))
        }
        let gen = runTOMLDifferential(generated)
        report("TOML generated (\(generated.count) documents)", "toml++",
               agreed: gen.agreed, bothRejected: gen.bothRejected,
               assayOnly: gen.assayOnlyRejected, oracleOnly: gen.oracleOnlyRejected,
               disagreed: gen.disagreed)
        print("TOML encode differential: \(runTOMLEncodeDifferential(corpus: corpus)) documents Assay wrote that toml++ reads back")
    },
    Oracle(name: "toml-test", summary: "the official toml-test suite (TOML_TEST_DIR names a checkout)") {
        guard let dir = ProcessInfo.processInfo.environment["TOML_TEST_DIR"] else {
            print("toml-test: skipped — set TOML_TEST_DIR to a checkout of github.com/toml-lang/toml-test")
            return
        }
        let r = runTOMLTestSuite(dir: URL(fileURLWithPath: dir))
        print("toml-test: \(r.validOK)/\(r.valid) valid documents parse to the expected value, \(r.invalidOK)/\(r.invalid) invalid documents refused")
    },
    Oracle(name: "encode", summary: "documents Assay wrote, read back by Foundation and libyaml") {
        print("encode differential: \(runEncodeDifferential(corpus: corpus)) documents Assay wrote that Foundation accepts")
        print("YAML encode differential: \(runYAMLEncodeDifferential(corpus: corpus)) documents Assay wrote that libyaml reads back")
        print("XML encode differential: \(runXMLEncodeDifferential(corpus: corpus)) documents Assay wrote that Foundation accepts")
    },
    Oracle(name: "dates", summary: "date parsers vs Foundation") {
        print("date differential: \(runDateDifferential()) instants agree with Foundation exactly")
    },
    Oracle(name: "reject", summary: "RFC 8259 accept/reject verdicts") {
        print("reject differential: \(runRejectDifferential()) documents, RFC 8259 accept/reject verdicts")
    },
    Oracle(name: "numbers", summary: "number literals bit-exact against the stdlib") {
        print("number differential: \(runNumberValueDifferential()) literals decode bit-exactly (oracle: the stdlib)")
    },
    Oracle(name: "formats", summary: "email/url/uuid/hostname validators vs a naive oracle") {
        if !runFormatDifferential() { Failures.shared.fail("format validators disagree with the naive oracle") }
    },
    Oracle(name: "plist", summary: "binary and XML plists vs Foundation") {
        let (plistBinary, plistXML) = try runPlistDifferential()
        print("plist differential: \(plistBinary) binary + \(plistXML) XML documents Foundation")
        print("    wrote decode to the same tree")
    },
    // The fuzz arm matters more here than the differential: a binary plist is steered by a
    // trailer at the END of the file, so one flipped byte redirects every subsequent read
    // rather than producing a parse error nearby. It found an Int(UInt64) trap on its first run.
    Oracle(name: "plist-fuzz", summary: "mutated/truncated/random plists, no crashes or traps") {
        print("plist fuzz: \(try runPlistFuzz()) mutated/truncated/random documents, no crashes, no traps")
    },
    Oracle(name: "fuzz", summary: "mutated/truncated JSON, YAML, XML, TOML and @Schema decode") {
        let n = try runFuzz(corpus: corpus)
        print("fuzz: \(n) mutated/truncated inputs, no crashes, no hangs")
        // Reported, not just counted: a law that only ever sees rejected documents is a
        // law nothing checks, and `accepted` is how you see that it does.
        print("      \(schemaChecks) @Schema decodes checked against three laws, "
              + "\(schemaAccepted) of them accepted")
        if schemaAccepted == 0 {
            fail("schema fuzz: nothing decoded, so the validate-its-own-output law never ran")
        }
    },
]

var args = Array(CommandLine.arguments.dropFirst())
if args.contains("--list") || args.contains("--help") {
    print("usage: DiffFuzz [--list] [oracle ...] | --probe <yaml|xml|toml|json> <input>")
    for o in oracles { print("  " + o.name.padding(toLength: 12, withPad: " ", startingAt: 0) + o.summary) }
    exit(0)
}
let selected: [Oracle] = args.isEmpty ? oracles : args.map { name in
    guard let o = oracles.first(where: { $0.name == name }) else {
        print("unknown oracle '\(name)' — DiffFuzz --list names them"); exit(2)
    }
    return o
}
for o in selected {
    if selected.count > 1 { print(""); print("== \(o.name) ==") }
    try o.run()
}

if Failures.shared.count > 0 {
    print("\(Failures.shared.count) FAILURES")
    exit(1)
}
print("OK")
