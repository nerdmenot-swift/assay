// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The golden shapes, as COMPILED CODE.
//
// `GoldenExpansionTests` reads this file and expands every declaration that follows a
// `// GOLDEN: <name>` marker (up to the next blank line), so the source a golden pins is
// the source the compiler type-checked. The first edition kept the shapes as strings in
// the test, and one of them — `@Check(\.a)` — was a spelling no user could write:
// `expandSchemaForTesting` does not type-check, so the golden passed on a declaration that
// does not compile. Now it cannot.
//
// Supporting types are declared above the markers with a `Golden` prefix so they collide
// with nothing else in the test target.
//===----------------------------------------------------------------------===//

import Foundation
import Assay
import AssayCore

@Schema(formats: .all, encodes: true)
struct GoldenNested: Equatable { var x: Int }

struct GoldenCtx: Sendable { let tenant: String }

@Schema(keys: .snakeCase, encodes: true)
struct GoldenA: Equatable { var x: Int }

@Schema(keys: .snakeCase, encodes: true)
struct GoldenB: Equatable { var y: String }

// GOLDEN: plain
@Schema struct GoldenPlain { var a: Int; var b: String?; var c: [Int] = []; var d: GoldenNested }

// GOLDEN: all-formats-snake
@Schema(keys: .snakeCase, formats: .all) struct GoldenAllFormats { var aB: Int; var c: [String]; var m: [String: Int] }

// GOLDEN: encodes-path-extras
@Schema(encodes: true) struct GoldenEncodes { var a: Int; @Key(path: "p.q") var q: Int; @Key("k", or: "kk") var k: String; @Extras var rest: [String: RawValue] }

// GOLDEN: rules-checks-async
@Schema struct GoldenRules {
    @Validate(.min(1), .email) var a: String
    @Validate(.count(1...3)) var t: [Int]
    @Preprocess(.trim) var p: String
    @Preprocess(.trim) @Transform({ (s: String) in s.count }) var n: Int
    @Fallback(0) var f: Int
    @Transform({ (a: [String]) in Set(a) }) var s: Set<String>
    @Check(\GoldenRules.a) static func f(_ a: String) -> String? { nil }
    @AsyncCheck static func g(_ v: GoldenRules, _ i: inout Issues<GoldenRules>) async {}
}

// GOLDEN: context
@Schema(context: GoldenCtx.self) struct GoldenContext { var a: Int; var n: GoldenNested }

// GOLDEN: describes
@Schema(unknownKeys: .reject, describes: true) struct GoldenDescribes { @Validate(.min(1)) var a: String; var b: Int? }

// GOLDEN: sources
@Schema(sources: true) struct GoldenSources { var a: Int; var b: String; var c: Double? }

// GOLDEN: xml-encodes-root
@Schema(coerceScalars: true, formats: .all, encodes: true) @XML(root: "r") struct GoldenXML { @XML(.attribute) var id: Int; @XML(.text) var body: String; @XML(.wrapped) var tags: [String] }

// GOLDEN: dates-inline
@Schema struct GoldenDates {
    struct P { var x: Int; @Key("yy") var y: Int }
    @Inline var p: P
    var when: Date
    @DateFormat(.unixSeconds, .iso8601) var ts: Date
}

// GOLDEN: tagged-union-encodes
@Schema(keys: .snakeCase, encodes: true, discriminator: "type") enum GoldenTagged { case click(GoldenA); @Key("pv") case pageView(GoldenB) }

// GOLDEN: untagged-union
@Schema(discriminator: .untagged) enum GoldenUntagged { case text(String); case number(Double); case b(GoldenB) }

// GOLDEN: open-enum
@Schema(encodes: true) enum GoldenOpen { case active, suspended; @Unknown(roundTrips: true) case other(String) }

// GOLDEN: one-or-many-narrow
@Schema(formats: .all) struct GoldenNarrow { @OneOrMany var tags: [String]; var w: UInt8; var bytes: [UInt8]; @Coerce var n: Int }
