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

@Schema(describes: true)
struct GoldenDescribedLeaf: Equatable { var x: Int }

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

// GOLDEN: describes-wide
/// The descriptor arms `describes` never reaches: it has a `String` with a rule and an
/// optional `Int`, so `DescribeGen` had only ever been shown two of its type tokens.
///
/// A `@Transform` field is the one that matters. `.input` and `.output` differ exactly
/// there — the wire holds milliseconds and the property holds seconds — and a descriptor
/// that recorded one type for both would describe a document this type rejects. A date's
/// wire type likewise depends on its FORMAT, so both spellings are here: `.unixSeconds` is
/// a number and the default is a string.
@Schema(describes: true) struct GoldenDescribesWide {
    @Validate(.min(1), .max(9)) var a: String
    @Transform({ (ms: Int) in Double(ms) / 1000.0 }) var seconds: Double
    @DateFormat(.unixSeconds) var at: Date; var on: Date
    var any: RawValue; var leaf: GoldenDescribedLeaf; var leaves: [GoldenDescribedLeaf]?
    var tally: [String: Double]; var flag: Bool; @Key("k", or: "kk") var k: Int
}

// GOLDEN: raw-encodes-path-extras
/// `encodes-path-extras` on the `RawValue` side. That fixture is JSON only, so the tree
/// encoder's path grouping (`rawPathValue`), its extras write-back with the collision
/// report, and the `UUID` arm were all emitted into no golden. Two fields share the `p`
/// prefix because a path group is ONE mapping, and an optional leaf sits under it because
/// that is the arm that writes `.null` for the encoder to omit.
@Schema(formats: [.json, .yaml], encodes: true) struct GoldenRawPaths {
    var id: UUID; @Key(path: "p.q") var q: Int; @Key(path: "p.r.s") var s: String?
    @Extras var rest: [String: RawValue]
}

// GOLDEN: wraps-string-rules
@Wraps(String.self, .min(3), .max(8)) struct GoldenHandle {}

// GOLDEN: wraps-int-bare
/// No rules: the arm that emits no `.validate(...)` at all, rather than an empty one.
@Wraps(Int64.self) struct GoldenCount {}

// GOLDEN: dates-collections
/// The collection and presence arms no fixture declared. `dates-inline` has a `Date` and
/// `plain` has `[Int]`; nothing had a `Date?`, a `[Date]`, a `[String: Date]`, an array of
/// arrays, a dictionary of arrays or of dictionaries, an open `[String: RawValue]` that is
/// not `@Extras`, an optional `RawValue`, or `@Coerce` on an optional. Each is its own
/// branch of `decodeStatement`, on both decode paths.
@Schema(formats: [.json, .yaml]) struct GoldenDatesWide {
    var maybe: Date?; var many: [Date]; var byName: [String: Date]
    var grid: [[Int]]; var lists: [String: [Int]]; var maps: [String: [String: Int]]
    var open: [String: RawValue]; var any: RawValue?; @Coerce var n: Int?
    @Fallback(0) var f: Int; @Fallback(Date(timeIntervalSince1970: 0)) var fb: Date
}

// GOLDEN: unknown-warn-alias
/// `unknownKeys: .warn` on both paths, with an alias — the warn arm of the JSON dispatch
/// and the `RawValue` loop's alias report.
@Schema(unknownKeys: .warn, formats: .all) struct GoldenWarns { @Key("a", or: "b") var a: Int }

// GOLDEN: unknown-reject-raw
@Schema(unknownKeys: .reject, formats: .all) struct GoldenRejects { var a: Int }

// GOLDEN: open-enum-all-formats
/// An open enum on every path, WITHOUT `roundTrips:` — so each encoder carries the refusal
/// for an unrecognised variant. `open-enum` is JSON only and round-trips.
@Schema(formats: .all, encodes: true) enum GoldenOpenAll {
    case active, suspended; @Unknown case other(String)
}

// GOLDEN: untagged-union-encodes
@Schema(encodes: true, discriminator: .untagged) enum GoldenUntaggedEncodes {
    case text(String); case number(Double); case b(GoldenB)
}

// GOLDEN: xml-encodes-wide
/// `XMLEncodeGen` past `xml-encodes-root`'s Int, String and wrapped array: an optional
/// attribute, a `UUID` and a `Date` in both placements, a `Float`, an open value and the
/// extras write-back.
@Schema(coerceScalars: true, formats: .all, encodes: true) struct GoldenXMLWide {
    @XML(.attribute) var a: Int?; @XML(.attribute) var uid: UUID; @XML(.attribute) var on: Date
    @XML(.attribute) var ratio: Double; var id: UUID; var at: Date; var f: Float; var any: RawValue
    var note: String?; @Extras var rest: [String: RawValue]
}

// GOLDEN: async-field-check
@Schema struct GoldenAsyncField {
    var a: String
    @AsyncCheck(\GoldenAsyncField.a) static func free(_ v: String) async -> String? { nil }
}

// GOLDEN: rule-shapes
/// Where a rule's call is chosen by the field's TYPE: an unsigned width, `UInt64` (the one
/// that needs no conversion), an array with no typed overload (count rules only), an
/// optional (validated only when present), two `@Validate` attributes on one field (two
/// rule arrays, joined for the descriptor), and a transformed field with its inverse.
@Schema(encodes: true, describes: true) struct GoldenRuleShapes {
    @Validate(.min(1)) var u: UInt; @Validate(.min(1)) var u64: UInt64
    @Validate(.notEmpty) var flags: [Bool]; @Validate(.min(1)) var opt: String?
    @Validate(.min(1)) @Validate(.max(9)) var two: String
    @Validate(.min(1)) @Transform({ (s: String) in s.count })
    @Inverse({ (n: Int) in String(repeating: "x", count: n) }) var width: Int
}

// GOLDEN: optional-path-group
/// A key path whose every leaf is optional: the group is checked only if it was present,
/// rather than reported missing.
@Schema struct GoldenOptionalGroup { @Key(path: "p.q") var q: Int?; var a: Int }

// GOLDEN: tree-only-warn-path
/// No JSON body at all, so the `RawValue` body is the one that declares the known keys.
@Schema(unknownKeys: .warn, formats: [.yaml]) struct GoldenTreeOnly {
    @Key(path: "p.q") var q: Int?; var a: Int
}

// GOLDEN: xml-optional-text
@Schema(formats: .xml, encodes: true) struct GoldenXMLText {
    @XML(.attribute) var lang: String; @XML(.text) var body: String?
}

// GOLDEN: open-enum-keyed
@Schema enum GoldenKeyedOpen { @Key("on") case active; case off; @Unknown case other(String) }

// GOLDEN: key-style-mixed
/// Names the snake-case converter has to split three ways: an acronym run, an identifier
/// that already contains an underscore, and a trailing acronym.
@Schema(keys: .snakeCase) struct GoldenKeyStyle {
    var HTTPResponse: Int; var already_snake: Int; var avatarURL: String
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
