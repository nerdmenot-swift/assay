// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Validating a value you already have, measured. docs/VALIDATE.md.
//
// One question decides whether this entry point is worth having, and it is not "is it
// fast" — it is **is it cheap enough to be free next to somebody else's decode**. The seam
// it exists for is:
//
//     let trips = try Table("trips.parquet").rows(of: Trip.self)   // their decode
//     try Trip.validate(trips)                                     // our rules
//
// A specialised columnar reader will decode a row in tens of nanoseconds. If validating
// that row costs the same again, the seam is a tax and a caller will skip it. So the
// number that matters is validation as a FRACTION of a decode, which is what the second
// table reports.
//
// The first table separates the two costs inside Assay's own pipeline, by decoding the
// same document through a schema with rules and one without. That difference is what
// `validate` re-runs, and it is the only honest reference point for the ratio.
//===----------------------------------------------------------------------===//

import Foundation
import Assay

@Schema(keys: .snakeCase)
struct RuledAccount: Equatable {
    @Validate(.min(3), .max(64)) var username: String
    @Validate(.email) var email: String
    @Validate(.range(13...120)) var age: Int
    @Validate(.min(1)) var tags: [String]
    @Validate(.min(0.0)) var score: Double
    var note: String
}

/// The same fields, no rules. The difference between the two decodes is the cost of the
/// rules themselves — which is the quantity `validate` re-runs.
@Schema(keys: .snakeCase)
struct PlainAccount: Equatable {
    var username: String
    var email: String
    var age: Int
    var tags: [String]
    var score: Double
    var note: String
}

func runValidateBenchmarks() {
    let json = Array("""
    {"username": "ada-lovelace", "email": "ada@example.com", "age": 36, \
    "tags": ["mathematics", "engines", "notes"], "score": 9.75, \
    "note": "the first programmer"}
    """.utf8)

    guard let value = try? RuledAccount.parse(json: json) else {
        print("validate benchmark: fixture does not parse"); return
    }
    precondition(RuledAccount.diagnose(value).isValid)

    let iters = 50_000

    print("")
    print("Validating a value you already have — docs/VALIDATE.md")
    print("The rules cost is isolated by decoding the same document through a schema")
    print("with rules and one without; validate re-runs exactly that.")
    print(pad("operation", 38, right: true) + pad("ns", 12) + pad("blocks", 10))
    print(String(repeating: "-", count: 60))

    let ruledNs = measure(iterations: iters) { _ = try? RuledAccount.parse(json: json) }
    let plainNs = measure(iterations: iters) { _ = try? PlainAccount.parse(json: json) }
    let validateNs = measure(iterations: iters) { _ = RuledAccount.diagnose(value) }
    let alloc = measureAllocations(iterations: 4_000) { () -> Box<Bool>? in
        Box(RuledAccount.diagnose(value).isValid)
    }

    func row(_ label: String, _ ns: Double, _ blocks: Double?) {
        print(pad(label, 38, right: true)
              + pad(String(format: "%.0f", ns), 12)
              + pad(blocks.map { String(format: "%.1f", $0) } ?? "n/a", 10))
    }
    row("decode, schema WITH rules", ruledNs, nil)
    row("decode, same schema NO rules", plainNs, nil)
    row("validate a constructed value", validateNs, alloc.blocks)

    print("")
    print(String(format: "rules cost inside a decode: %.0f ns (%.1f%% of it)",
                 ruledNs - plainNs, (ruledNs - plainNs) / ruledNs * 100))
    print(String(format: "validating separately:      %.0f ns (%.2fx a full decode)",
                 validateNs, validateNs / ruledNs))

    // THE QUESTION THE SEAM TURNS ON. A columnar reader decodes a row in tens of ns.
    // Validation has to be small against that or nobody will call it.
    print("")
    print("As a fraction of a fast decode — the seam this entry point exists for")
    print(pad("rows", 10, right: true) + pad("validate ns", 14) + pad("per row", 10)
          + pad("vs 53 ns/row", 14))
    print(String(repeating: "-", count: 50))

    for n in [64, 1_000, 20_000, 100_000] {
        let batch = Array(repeating: value, count: n)
        let reps = max(1, 400_000 / n)
        let ns = measure(iterations: reps) {
            let v = RuledAccount.diagnose(batch)
            precondition(v.isValid)
        }
        let perRow = ns / Double(n)
        print(pad("\(n)", 10, right: true)
              + pad(String(format: "%.0f", ns), 14)
              + pad(String(format: "%.0f", perRow), 10)
              + pad(String(format: "%.2fx", perRow / 53.0), 14))
    }
    print("53 ns/row is this machine's columnar batch fill, from the table above — the")
    print("fastest decode Assay itself has, and a fair stand-in for a specialised reader.")

    // The failing path, which is the one a real dataset takes. Reporting must not be so
    // much more expensive than accepting that a bad file becomes a denial of service.
    print("")
    var bad = value
    bad.age = 500
    bad.email = "nope"
    let badBatch = Array(repeating: bad, count: 1_000)
    let cleanBatch = Array(repeating: value, count: 1_000)
    let cleanNs = measure(iterations: 400) { _ = RuledAccount.diagnose(cleanBatch) }
    let badNs = measure(iterations: 400) {
        _ = RuledAccount.diagnose(badBatch, limits: Limits(maxIssues: 100))
    }
    print(String(format: "1,000 rows, all clean:  %.0f ns", cleanNs))
    print(String(format: "1,000 rows, all failing: %.0f ns (%.2fx) — bounded by maxIssues,",
                 badNs, badNs / cleanNs))
    print("which is why one sink covers the batch rather than one per element.")
}

// MARK: - Per-rule cost
//
// 42 ns per rule is an aggregate, and an aggregate hides which rule is expensive. Each type
// below carries ONE rule over the same field, so the rows are directly comparable. Written
// out rather than looped because the whole point is that each is a separate monomorphic
// expansion.
//
// The FIXED cost of a `diagnose` call — building an IssueSink, the call itself — is
// measured rather than guessed, by comparing one `.range` against two identical ones on the
// same field. The second rule adds only its own work, so the difference is one rule's
// marginal cost and total minus twice that is the fixed part. Subtracting a floor you
// assumed instead of measured is how a per-rule table ends up reporting negative numbers.

@Schema struct RMin { @Validate(.min(3)) var s: String }
@Schema struct RMax { @Validate(.max(64)) var s: String }
@Schema struct REmail { @Validate(.email) var s: String }
@Schema struct RURL { @Validate(.url) var s: String }
@Schema struct RUUID { @Validate(.uuid) var s: String }
@Schema struct RRange { @Validate(.range(13...120)) var n: Int }
@Schema struct RRange2 { @Validate(.range(13...120), .range(0...200)) var n: Int }
@Schema struct RCount { @Validate(.min(1)) var a: [String] }

func runRuleCostBenchmarks() {
    let iters = 200_000

    let one = measure(iterations: iters) { _ = RRange.diagnose(RRange(n: 36)) }
    let two = measure(iterations: iters) { _ = RRange2.diagnose(RRange2(n: 36)) }
    let marginal = two - one
    let fixed = one - marginal

    print("")
    print("Per-rule cost — one rule per type, against the same value")
    print(String(format: "fixed cost of a diagnose call: %.1f ns (measured, see source)",
                 fixed))
    print(pad("rule", 26, right: true) + pad("total ns", 12) + pad("rule ns", 12))
    print(String(repeating: "-", count: 50))

    func line(_ name: String, _ ns: Double) {
        print(pad(name, 26, right: true)
              + pad(String(format: "%.1f", ns), 12)
              + pad(String(format: "%.1f", ns - fixed), 12))
    }
    line(".range(13...120) on Int", one)
    line(".min(3) on String",
         measure(iterations: iters) { _ = RMin.diagnose(RMin(s: "ada@example.com")) })
    line(".max(64) on String",
         measure(iterations: iters) { _ = RMax.diagnose(RMax(s: "ada@example.com")) })
    line(".min(1) on [String]",
         measure(iterations: iters) { _ = RCount.diagnose(RCount(a: ["x"])) })
    line(".email",
         measure(iterations: iters) { _ = REmail.diagnose(REmail(s: "ada@example.com")) })
    line(".url",
         measure(iterations: iters) { _ = RURL.diagnose(RURL(s: "https://example.com/a")) })
    line(".uuid",
         measure(iterations: iters) {
             _ = RUUID.diagnose(RUUID(s: "f81d4fae-7dec-11d0-a765-00a0c91e6bf6")) })
}
