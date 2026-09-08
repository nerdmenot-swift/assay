// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `@Key(path:)` against the alternative it replaces. Added 2026-09-08.
//
// THE GATE WAS WRITTEN BEFORE THE NUMBER, which is the only way a ship-or-refuse rule means
// anything: **if `@Key(path:)` is not within 1.15x of the nested-`@Schema` alternative, it
// does not ship** — `ROADMAP.md` §3's stated fallback ("the honest answer is a nested @Schema
// type") would then still be the right answer, and shipping a slower spelling of it would be
// selling convenience with an unmentioned bill.
//
// WHAT IS COMPARED, and it is deliberately the *whole* decode rather than a path microbench.
// `DiagnosticPathBench.swift` records what happens otherwise: an isolated path-concat reads
// ~49 ns and the same code in situ measures ~1 ns, because the optimiser sees through the
// isolated version. Two complete schemas over byte-identical documents is the only comparison
// that cannot be gamed that way.
//
//   nested   — three declared types, the spelling available before this feature
//   paths    — one type, four `@Key(path:)` fields reaching the same four leaves
//
// The documents are identical. The RESULTS are not: `nested` materialises two extra structs
// the caller then has to reach through, and `paths` produces the four values directly. That
// asymmetry favours `paths` and is stated rather than hidden — a fair reading of the ratio is
// "the walk costs no more than the nesting", not "paths are faster".
//===----------------------------------------------------------------------===//

import Assay

// The alternative: declare the shape.
@Schema(keys: .snakeCase)
struct BenchProfile {
    var displayName: String
    var avatar: String
}

@Schema(keys: .snakeCase)
struct BenchStats {
    var views: Int
    var likes: Int
}

@Schema(keys: .snakeCase)
struct BenchMeta {
    var stats: BenchStats
}

@Schema(keys: .snakeCase)
struct NestedCard {
    var id: String
    var profile: BenchProfile
    var meta: BenchMeta
}

// The feature: reach through it.
@Schema(keys: .snakeCase)
struct PathCard {
    var id: String
    @Key(path: "profile.display_name") var displayName: String
    @Key(path: "profile.avatar") var avatar: String
    @Key(path: "meta.stats.views") var views: Int
    @Key(path: "meta.stats.likes") var likes: Int
}

/// A wider schema, to check the claim that a group costs ONE dispatch arm rather than one per
/// field: if the cost grew with the number of fields under a prefix, this would diverge.
@Schema(keys: .snakeCase)
struct WidePathCard {
    var id: String
    var kind: String
    var region: String
    @Key(path: "profile.display_name") var displayName: String
    @Key(path: "profile.avatar") var avatar: String
    @Key(path: "meta.stats.views") var views: Int
    @Key(path: "meta.stats.likes") var likes: Int
}

func runKeyPathBenchmarks() {
    let doc = Array(#"""
        {"id":"card-00000000","profile":{"display_name":"A name of ordinary length",\
        "avatar":"https://example.com/avatars/00000000.png"},\
        "meta":{"stats":{"views":128,"likes":7}}}
        """#.replacingOccurrences(of: "\\\n", with: "").utf8)

    let wide = Array(#"""
        {"id":"card-00000000","kind":"article","region":"eu-west-1",\
        "profile":{"display_name":"A name of ordinary length",\
        "avatar":"https://example.com/avatars/00000000.png"},\
        "meta":{"stats":{"views":128,"likes":7}}}
        """#.replacingOccurrences(of: "\\\n", with: "").utf8)

    print("")
    print("@Key(path:) vs the nested-@Schema alternative")
    print("Ship-or-refuse, written before the measurement: within 1.15x or it does not ship.")
    print("Identical documents; `nested` also materialises two structs the caller must reach")
    print("through, which favours `paths`. Read the ratio as \"the walk costs no more\".")
    print("")
    print(pad("shape", 16, right: true) + pad("bytes", 8) + pad("nested ns", 12)
          + pad("paths ns", 12) + pad("ratio", 10))
    print(String(repeating: "-", count: 58))

    // Sanity: both must actually decode, or the comparison times two error paths.
    guard let n = try? NestedCard.parse(json: doc),
          let p = try? PathCard.parse(json: doc),
          n.profile.displayName == p.displayName, n.meta.stats.likes == p.likes else {
        print("  SKIPPED — the two schemas disagree, so the comparison is meaningless")
        return
    }

    let reps = 20_000
    let nested = measure(iterations: reps) { _ = try? NestedCard.parse(json: doc) }
    let paths = measure(iterations: reps) { _ = try? PathCard.parse(json: doc) }
    print(pad("4 leaves", 16, right: true) + pad("\(doc.count)", 8)
          + pad(String(format: "%.0f", nested), 12)
          + pad(String(format: "%.0f", paths), 12)
          + pad(String(format: "%.2fx", paths / nested), 10))

    let widePaths = measure(iterations: reps) { _ = try? WidePathCard.parse(json: wide) }
    print(pad("+3 plain keys", 16, right: true) + pad("\(wide.count)", 8)
          + pad("-", 12)
          + pad(String(format: "%.0f", widePaths), 12)
          + pad(String(format: "%.2fx", widePaths / paths), 10))

    let ratio = paths / nested
    print("")
    print(ratio <= 1.15
          ? String(format: "GATE PASSED — %.2fx of the nested alternative (limit 1.15x)", ratio)
          : String(format: "GATE FAILED — %.2fx, over the 1.15x limit. ROADMAP §3's fallback stands.", ratio))
}
