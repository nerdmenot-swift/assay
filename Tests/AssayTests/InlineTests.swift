// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `@Inline`, built 2026-09-08. EXPERIENCE §4, ROADMAP §3.
//
// ROADMAP recorded this as blocked on "whether cross-module collision detection is
// achievable at all". That was the wrong diagnosis, and correcting it is what unblocked the
// feature: an attached macro receives the syntax of the declaration it is attached to and
// nothing else, so it cannot see another type's members in ANY module — including one
// declared three lines above in the same file. There is no module in which it works.
//
// Requiring the inlined type to be NESTED makes the members visible, so collision detection
// is total and at expansion, and `collisionIsCompileTimeError` is the test that says so.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayYAML

@Schema(unknownKeys: .reject)
struct Response: Equatable {
    struct Pagination: Equatable {
        var page: Int
        @Key("per_page") var perPage: Int
    }
    @Inline var pagination: Pagination
    var items: [String]
}

/// The equivalent flat type. Decoding must be indistinguishable.
@Schema(unknownKeys: .reject)
struct FlatResponse: Equatable {
    var page: Int
    @Key("per_page") var perPage: Int
    var items: [String]
}

@Schema(formats: .all)
struct MultiFormatResponse: Equatable {
    struct Meta: Equatable { var page: Int; var total: Int }
    @Inline var meta: Meta
    var name: String
}

@Suite("@Inline")
struct InlineTests {

    @Test("the nested type's keys are read from this level")
    func flattens() throws {
        let r = try Response.parse(json: Array(
            #"{"page":2,"per_page":50,"items":["a","b"]}"#.utf8))
        #expect(r.pagination.page == 2)
        #expect(r.pagination.perPage == 50)
        #expect(r.items == ["a", "b"])
    }

    /// A `@Key` rename inside the nested type survives the flattening — the nested fields
    /// keep everything except their namespace.
    @Test("nested @Key renames still apply")
    func nestedKeyRename() {
        let d = Response.diagnose(json: Array(#"{"page":2,"perPage":50,"items":[]}"#.utf8))
        #expect(!d.isValid, "camelCase should not match the renamed key")
    }

    /// **The claim serde's runtime `flatten` cannot make.** The inlined keys are known at
    /// compile time, so they are in the outer type's known-key set and `.reject` does not
    /// fire on them.
    @Test("unknown-key handling works through an inline")
    func unknownKeysThroughInline() throws {
        // Inlined keys are KNOWN, so this is accepted under .reject.
        _ = try Response.parse(json: Array(#"{"page":1,"per_page":10,"items":[]}"#.utf8))

        // A genuinely unknown key is still rejected.
        let d = Response.diagnose(json: Array(
            #"{"page":1,"per_page":10,"items":[],"nope":1}"#.utf8))
        #expect(!d.isValid)
        #expect(d.issues.contains { $0.code == .unknownKey })
    }

    /// Decoding through an inline must be indistinguishable from the flat equivalent —
    /// that is the whole point, and a missing key is where a difference would show.
    @Test("an inlined type decodes identically to the flat equivalent")
    func identicalToFlat() {
        let json = Array(#"{"page":1,"items":[]}"#.utf8)     // per_page missing
        let inlined = Response.diagnose(json: json)
        let flat = FlatResponse.diagnose(json: json)
        #expect(inlined.isValid == flat.isValid)
        #expect(inlined.issues.map(\.code) == flat.issues.map(\.code))
        #expect(inlined.issues.map(\.path) == flat.issues.map(\.path))
    }

    @Test("it works on the tree paths too")
    func multiFormat() throws {
        let y = try MultiFormatResponse.parse(yaml: "page: 1\ntotal: 9\nname: x\n")
        #expect(y.meta.page == 1)
        #expect(y.meta.total == 9)
    }

    /// **The reason the nested-only restriction exists.** Two structs sharing one key
    /// namespace can collide, and because the members are visible the collision is caught
    /// at expansion rather than becoming a last-writer-wins surprise at runtime.
    @Test("a key collision is a compile-time error")
    func collisionIsCompileTimeError() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S {
            struct Inner { var page: Int }
            @Inline var inner: Inner
            var page: Int
        }
        """)
        #expect(!diags.isEmpty, "a duplicate key must be diagnosed")
    }

    @Test("a non-nested type is refused, and the message says why")
    func nonNestedRefused() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S { @Inline var p: Elsewhere; var x: Int }
        """)
        #expect(diags.contains { $0.contains("declared inside") }, "got \(diags)")
        #expect(diags.contains { $0.contains("cannot see another type's members") },
                "the message should say WHY, not just what: \(diags)")
    }

    /// `all absent` and `some absent` are indistinguishable when the keys live at this
    /// level, so there is no honest answer for which one means nil.
    @Test("an optional inline is refused")
    func optionalRefused() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S {
            struct Inner { var a: Int }
            @Inline var inner: Inner?
            var x: Int
        }
        """)
        #expect(diags.contains { $0.contains("cannot be optional") }, "got \(diags)")
    }
}
