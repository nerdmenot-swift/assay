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
import AssayFoundation

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
@Schema(keys: .snakeCase, formats: .all) struct GoldenAllFormats {
    var aB: Int; var c: [String]; var m: [String: Int]
}

// GOLDEN: array-element
/// The element type `array-of-schemas` holds. Pinned separately because that fixture's
/// golden shows the CONTAINING type's loop, not this type's own body.
@Schema struct GoldenArrayElement { var x: Int; var y: String }

// GOLDEN: array-of-schemas
/// An array of nested schemas — the hottest emitted shape, and the one nothing pinned.
///
/// Every other fixture's arrays hold scalars, which take a different arm. When the
/// per-element diagnostic path was hoisted out of this loop on 2026-09-13 (a 2.5x win),
/// the golden suite did not notice, because no fixture reached that emitter branch.
@Schema struct GoldenArrayOfSchemas { var name: String; var items: [GoldenArrayElement] }

// GOLDEN: encodes-path-extras
/// `encodes: true` with a key path and an `@Extras` bag, which is three emitters at once:
/// EncodeGen's member writer, the path group's nested dispatch, and the extras projection.
///
/// THE MARKER FOR THIS SAT ONE STANZA TOO HIGH until 2026-10-02, so this declaration was
/// captured by nothing and `encodes-path-extras.swift.golden` pinned `GoldenArrayElement` —
/// a plain two-field struct with no encoder, no path and no extras in it. The suite had a
/// golden named for a shape it did not contain, and the shape it was named for was unpinned.
@Schema(encodes: true) struct GoldenEncodes {
    var a: Int; @Key(path: "p.q") var q: Int; @Key("k", or: "kk") var k: String;
    @Extras var rest: [String: RawValue]
}

// GOLDEN: raw-encodes-wide
/// The `RawValue` encode path, with the field shapes nothing else in this file gives it.
///
/// `xml-encodes-root` is the only other `formats: .all, encodes: true` fixture, and between
/// them its three fields show `RawEncodeGen` an `Int`, a `String` and a `[String]`. Every
/// other arm of that emitter — optional, `Double`, `Bool`, a nested schema, an array of
/// nested schemas, a dictionary, a `Date` with a format, a narrow integer width — was
/// emitted into nobody's golden, which is most of why the file sat near half covered.
@Schema(keys: .snakeCase, formats: .all, encodes: true)
struct GoldenRawWide: Equatable {
    var count: Int
    var ratio: Double
    var enabled: Bool
    var label: String?
    var width: UInt16
    var child: GoldenNested
    var children: [GoldenNested]
    var tally: [String: Int]
    @DateFormat(.unixSeconds) var at: Date
}

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
@Schema(unknownKeys: .reject, describes: true) struct GoldenDescribes {
    @Validate(.min(1)) var a: String; var b: Int?
}

// GOLDEN: xml-encodes-root
@Schema(coerceScalars: true, formats: .all, encodes: true) @XML(root: "r") struct GoldenXML {
    @XML(.attribute) var id: Int; @XML(.text) var body: String; @XML(.wrapped) var tags: [String]
}

// GOLDEN: dates-inline
@Schema struct GoldenDates {
    struct P { var x: Int; @Key("yy") var y: Int }
    @Inline var p: P
    var when: Date
    @DateFormat(.unixSeconds, .iso8601) var ts: Date
    var id: UUID
}

// GOLDEN: tagged-union-encodes
@Schema(keys: .snakeCase, encodes: true, discriminator: "type") enum GoldenTagged {
    case click(GoldenA); @Key("pv") case pageView(GoldenB)
}

// GOLDEN: untagged-union
@Schema(discriminator: .untagged) enum GoldenUntagged {
    case text(String); case number(Double); case b(GoldenB)
}

// GOLDEN: open-enum
@Schema(encodes: true) enum GoldenOpen {
    case active, suspended; @Unknown(roundTrips: true) case other(String)
}

// GOLDEN: one-or-many-narrow
@Schema(formats: .all) struct GoldenNarrow {
    @OneOrMany var tags: [String]; var w: UInt8; var bytes: [UInt8]; @Coerce var n: Int
}
