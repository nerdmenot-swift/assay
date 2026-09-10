// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The driver. `AssayBench --list` names every arm; `AssayBench encode zippy` runs two of
// them; `AssayBench` with no arguments runs everything, in the order RESULTS.md reports.
//
// Until 2026-09-10 this file was the falsification check, the allocation gate and twenty
// unconditional `run*()` calls in one 500-line script, with no way to run one arm. Every
// benchmark-affecting change cost the full eight minutes, and a concurrent compile-time
// measurement once contaminated a run that then had to be discarded. Now each arm is a
// name, the allocation gate is the arm CI runs alone, and the summary is printed only for
// the arms that ran.
//===----------------------------------------------------------------------===//

import Foundation
import Assay

struct Arm {
    let name: String
    let summary: String
    /// Returns false when the arm is a GATE and it failed.
    let run: () -> Bool
}

// MainActor-isolated globals from a top-level script are fine to read from here; the arms
// close over nothing mutable.
var falsification: FalsificationResult? = nil

let arms: [Arm] = [
    Arm(name: "falsification", summary: "struct decode / prefix+skip / value model / negative path vs Foundation") {
        falsification = runFalsification()
        return falsification != nil
    },
    Arm(name: "allocations", summary: "live blocks per decoded value — the CI gate") { runAllocationGate() },
    Arm(name: "formats", summary: "YAML and XML vs Yams / Foundation") { runFormatBenchmarks(corpusDir: corpusDir, sizes: sizes); return true },
    Arm(name: "toml", summary: "TOML vs toml++ (TOMLKit)") { runTOMLBenchmarks(corpusDir: corpusDir, sizes: sizes); return true },
    Arm(name: "encode", summary: "JSON/YAML/XML encoding vs JSONEncoder") { runEncodeBenchmarks(); return true },
    Arm(name: "keypath", summary: "@Key(path:) vs nested @Schema") { runKeyPathBenchmarks(); return true },
    Arm(name: "coldstart", summary: "first decode per type, 60 types") { runColdStartBenchmarks(); return true },
    Arm(name: "largedoc", summary: "0.2–8 MB documents") { runLargeDocumentBenchmarks(); return true },
    Arm(name: "totalalloc", summary: "total malloc traffic (Darwin only)") { runTotalAllocationBenchmarks(); return true },
    Arm(name: "zippy", summary: "vs ZippyJSON (simdjson + Codable)") { runZippyBenchmarks(); return true },
    Arm(name: "dates", summary: "Date fields vs JSONDecoder .iso8601") { runDateBenchmarks(corpusDir: corpusDir, sizes: sizes); return true },
    Arm(name: "columnar", summary: "ColumnarSource batch decode") { runSourceBenchmarks(); return true },
    Arm(name: "columndecodable", summary: "the ColumnDecodable extension point") { runColumnDecodableBenchmarks(); return true },
    Arm(name: "pathab", summary: "generic vs concrete entry point") { runPathAB(); return true },
    Arm(name: "validate", summary: "T.validate(_:) on an existing value") { runValidateBenchmarks(); return true },
    Arm(name: "rules", summary: "per-rule cost of the rule engine") { runRuleCostBenchmarks(); return true },
    Arm(name: "simd", summary: "the SIMD-tier baseline (yyjson)") { runSIMDBaselineBenchmarks(corpusDir: corpusDir, sizes: sizes); return true },
    Arm(name: "decomposition", summary: "where decode time goes") { runDecompositionBenchmarks(corpusDir: corpusDir, sizes: sizes); return true },
    Arm(name: "dict", summary: "[String: T] dictionary fields") { runDictionaryBenchmarks(corpusDir: corpusDir, sizes: sizes); return true },
]

@MainActor
func usage() {
    print("usage: AssayBench [--list] [arm ...]")
    print("  no arguments runs every arm in order; --list names them")
    for a in arms { print("  " + pad(a.name, 18, right: true) + a.summary) }
}

var args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") { usage(); exit(0) }
if args.contains("--list") { usage(); exit(0) }
args.removeAll { $0 == "--all" }

let selected: [Arm]
if args.isEmpty {
    selected = arms
} else {
    var picked: [Arm] = []
    for name in args {
        guard let arm = arms.first(where: { $0.name == name }) else {
            print("unknown arm '\(name)'"); print(""); usage(); exit(2)
        }
        picked.append(arm)
    }
    selected = picked
}

print("AssayBench — \(selected.count == arms.count ? "every arm" : selected.map(\.name).joined(separator: ", "))")
print("Toolchain: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("Warm (decoder hoisted). Minimum of 5 rounds. -O. Scalar Swift, no SIMD, no C.")
print("")

var gateFailed = false
for arm in selected {
    if arm.name != "falsification" { print(""); print("== \(arm.name) ==") }
    if !arm.run() { gateFailed = true }
}

if let f = falsification {
    print("")
    print("Summary")
    print(String(repeating: "=", count: 40))
    func summarise(_ label: String, _ rs: [Double]) {
        guard !rs.isEmpty else { return }
        print(String(format: "%@: %.2fx mean over %d files",
                     label, rs.reduce(0, +) / Double(rs.count), rs.count))
    }
    summarise("struct decode      ", f.structRatios)
    summarise("prefix + skip      ", f.prefixRatios)
    summarise("generic value model", f.valueRatios)
    print("")
    print("Every ratio above is this machine, this toolchain, warm, minimum of 5 rounds.")
    print("None of them is a claim about another platform — see CLAUDE.md's honesty rules.")
}

if gateFailed { exit(1) }
