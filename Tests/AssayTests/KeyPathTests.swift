// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `@Key(path:)`, built 2026-09-08. EXPERIENCE §4, ROADMAP §3.
//
// The suite that matters here is `PresenceMatrix`: the five presence states crossed with the
// three ways a path can fail. A half-implementation passes the happy path and every simple
// error case, and gets the matrix wrong — which is why it is written out rather than sampled.
//
// The rules under test, from `Sources/AssayMacros/PathKeys.swift`:
//
//   * a MISSING intermediate is ABSENCE — an optional stays nil, a default applies, a
//     @Fallback fires, and a required field reports `.missing` naming the INTERMEDIATE, once
//     for the group rather than once per field under it;
//   * a WRONG-TYPED intermediate is an ERROR even when every field under it is optional,
//     because `missing != wrong` is law everywhere else here;
//   * a missing LEAF reports `.missing` at the full path.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayCore

@Schema
struct Card: Equatable {
    @Key(path: "profile.display_name") var displayName: String
    @Key(path: "profile.avatar") var avatar: String?
    @Key(path: "meta.stats.views") var views: Int
    var id: String
}

/// One group, every presence state, so the matrix has somewhere to run.
@Schema
struct Presence: Equatable {
    @Key(path: "outer.required") var req: String
    @Key(path: "outer.optional") var opt: String?
    @Key(path: "outer.defaulted") var def: Int = 7
    @Key(path: "outer.fallen") @Fallback("F") var fb: String
}

/// Every field under the group is optional — so the group's absence is not an issue, and its
/// being the wrong type still is.
@Schema
struct AllOptional: Equatable {
    @Key(path: "wrap.a") var a: String?
    @Key(path: "wrap.b") var b: Int?
}

/// Paths beside ordinary keys, rules, and a collection under a path.
@Schema(keys: .snakeCase)
struct Mixed: Equatable {
    var plainKey: String
    @Key(path: "nested.tags") var tags: [String]
    @Key(path: "nested.count") @Validate(.range(0...10)) var count: Int
}

@Suite("@Key(path:)")
struct KeyPathTests {

    @Test("a path reaches through an intermediate object")
    func reaches() throws {
        let c = try Card.parse(json: #"""
            {"id":"x","profile":{"display_name":"Ada","avatar":"a.png"},
             "meta":{"stats":{"views":9}}}
            """#)
        #expect(c == Card(displayName: "Ada", avatar: "a.png", views: 9, id: "x"))
    }

    /// One pass, any order. The path arm is an ordinary arm of the same dispatch table, so a
    /// document that puts `id` last decodes exactly as one that puts it first.
    @Test("key order does not matter")
    func anyOrder() throws {
        let c = try Card.parse(json: #"""
            {"meta":{"stats":{"views":1}},"profile":{"avatar":null,"display_name":"B"},"id":"y"}
            """#)
        #expect(c.displayName == "B")
        #expect(c.avatar == nil)
        #expect(c.views == 1)
    }

    @Test("three levels deep")
    func threeLevels() throws {
        let c = try Card.parse(json: #"""
            {"id":"x","profile":{"display_name":"A"},"meta":{"stats":{"views":42}}}
            """#)
        #expect(c.views == 42)
    }

    /// Keys the schema does not declare are skipped at every level, not just the top.
    @Test("unknown keys inside an intermediate are skipped")
    func unknownInside() throws {
        let c = try Card.parse(json: #"""
            {"id":"x","profile":{"other":{"deep":[1,2]},"display_name":"A","junk":null},
             "meta":{"stats":{"views":0,"extra":"s"},"more":1}}
            """#)
        #expect(c.displayName == "A")
        #expect(c.views == 0)
    }

    @Test("paths coexist with ordinary keys, rules and collections")
    func mixed() throws {
        let m = try Mixed.parse(json: #"""
            {"plain_key":"p","nested":{"tags":["a","b"],"count":3}}
            """#)
        #expect(m == Mixed(plainKey: "p", tags: ["a", "b"], count: 3))

        let bad = Mixed.diagnose(json: #"{"plain_key":"p","nested":{"tags":[],"count":99}}"#)
        #expect(!bad.isValid)
        #expect(bad.issues.first?.path.pathDescription.contains("count") == true,
                "\(bad.issues.map(\.path.pathDescription))")
    }
}

@Suite("@Key(path:) — the presence matrix")
struct PresenceMatrix {

    // MARK: the intermediate is missing

    /// **The rule that is easiest to get wrong.** `profile` is absent, so `profile` is what
    /// is missing — not `profile.display_name`, and not once per field under it.
    @Test("a missing intermediate reports the intermediate, once")
    func missingIntermediateReportsItself() {
        let d = Card.diagnose(json: #"{"id":"x","meta":{"stats":{"views":1}}}"#)
        #expect(!d.isValid)
        let profileIssues = d.issues.filter { $0.path.pathDescription.contains("profile") }
        #expect(profileIssues.count == 1,
                "expected one issue for the group, got \(profileIssues.map(\.path.pathDescription))")
        #expect(profileIssues.first?.code == .missing)
        #expect(profileIssues.first?.path.pathDescription == "profile",
                "got \(profileIssues.first?.path.pathDescription ?? "nil")")
    }

    @Test("a missing intermediate leaves optionals nil and defaults applied")
    func missingIntermediateIsAbsence() throws {
        // `outer` is entirely absent. `req` is required so this cannot succeed — but the
        // ONLY issue must be about `outer`, proving the other three states saw absence.
        let d = Presence.diagnose(json: #"{}"#)
        #expect(d.issues.count == 1, "\(d.issues.map(\.path.pathDescription))")
        #expect(d.issues.first?.path.pathDescription == "outer")
    }

    @Test("a missing intermediate is not an issue when nothing under it is required")
    func missingIntermediateAllOptional() throws {
        let v = try AllOptional.parse(json: #"{}"#)
        #expect(v == AllOptional(a: nil, b: nil))
    }

    @Test("an explicit null intermediate is absence, like a missing one")
    func nullIntermediate() throws {
        let v = try AllOptional.parse(json: #"{"wrap":null}"#)
        #expect(v == AllOptional(a: nil, b: nil))
    }

    // MARK: the intermediate is the wrong type

    /// Missing is absence; wrong is an error. This holds even here, where every field under
    /// `wrap` is optional and absence would have been silent.
    @Test("a wrong-typed intermediate is an error even when every field under it is optional")
    func wrongTypedIntermediateWithOnlyOptionals() {
        let d = AllOptional.diagnose(json: #"{"wrap":42}"#)
        #expect(!d.isValid, "a scalar where an object was declared must not be silent")
        #expect(d.issues.first?.code == .typeMismatch)
        #expect(d.issues.first?.path.pathDescription == "wrap")
    }

    @Test("a wrong-typed intermediate carries a caret on the value")
    func wrongTypedIntermediateCaret() {
        let d = AllOptional.diagnose(json: #"{"wrap":42}"#)
        #expect(d.issues.first?.location != nil,
                "the caret should point at the 42 — the innermost thing that existed")
    }

    @Test("an array intermediate is a mismatch, not a descent")
    func arrayIntermediate() {
        let d = AllOptional.diagnose(json: #"{"wrap":[{"a":"x"}]}"#)
        #expect(!d.isValid)
        #expect(d.issues.first?.code == .typeMismatch)
    }

    // MARK: the leaf is missing

    @Test("a missing leaf reports the full path")
    func missingLeaf() {
        let d = Card.diagnose(json: #"{"id":"x","profile":{},"meta":{"stats":{"views":1}}}"#)
        #expect(!d.isValid)
        let issue = d.issues.first { $0.code == .missing }
        #expect(issue?.path.pathDescription == "profile.display_name",
                "got \(issue?.path.pathDescription ?? "nil")")
    }

    @Test("a missing leaf leaves the other states alone")
    func missingLeafOthersUnaffected() {
        let d = Presence.diagnose(json: #"{"outer":{}}"#)
        #expect(d.issues.count == 1, "\(d.issues.map(\.path.pathDescription))")
        #expect(d.issues.first?.path.pathDescription == "outer.required")
    }

    /// The five presence states, under a path, all at once. `@Fallback` warns rather than
    /// failing, exactly as it does on a top-level key.
    @Test("optional, default and @Fallback all behave normally under a path")
    func allStatesTogether() throws {
        let v = try Presence.parse(json: #"{"outer":{"required":"R"}}"#)
        #expect(v.req == "R")
        #expect(v.opt == nil)
        #expect(v.def == 7)
        #expect(v.fb == "F")
    }

    @Test("a wrong-typed leaf reports at the full path, not the intermediate")
    func wrongTypedLeaf() {
        let d = Card.diagnose(json: #"""
            {"id":"x","profile":{"display_name":42},"meta":{"stats":{"views":1}}}
            """#)
        #expect(!d.isValid)
        #expect(d.issues.first?.code == .typeMismatch)
        #expect(d.issues.first?.path.pathDescription == "profile.display_name",
                "got \(d.issues.first?.path.pathDescription ?? "nil")")
    }

    /// A missing intermediate must not suppress an unrelated failure elsewhere.
    @Test("failures in different groups are all reported")
    func independentGroups() {
        let d = Card.diagnose(json: #"{"id":"x"}"#)
        #expect(d.issues.count == 2, "\(d.issues.map(\.path.pathDescription))")
        #expect(Set(d.issues.map(\.path.pathDescription)) == ["profile", "meta"])
    }
}

@Suite("@Key(path:) — expansion-time refusals")
struct KeyPathDiagnostics {

    @Test("a path with no dot names a top-level key, and says so")
    func noDot() {
        let (_, diags) = expandSchemaForTesting(
            "@Schema struct S { @Key(path: \"name\") var name: String }")
        #expect(diags.contains { $0.contains("has no `.`") && $0.contains("@Key(\"name\")") },
                "got \(diags)")
    }

    @Test("an empty segment is refused")
    func emptySegment() {
        let (_, diags) = expandSchemaForTesting(
            "@Schema struct S { @Key(path: \"a..b\") var x: String }")
        #expect(diags.contains { $0.contains("empty segment") }, "got \(diags)")
    }

    /// `EXPERIENCE.md` §4 advertises `meta.tags[0]`. It is not built, and the diagnostic says
    /// why rather than saying "invalid" — indexing an array is a different operation from
    /// walking a key.
    @Test("an index segment is refused with the reason")
    func indexSegment() {
        let (_, diags) = expandSchemaForTesting(
            "@Schema struct S { @Key(path: \"meta.tags[0]\") var t: String }")
        #expect(diags.contains { $0.contains("index segment") && $0.contains("nested @Schema") },
                "got \(diags)")
    }

    /// One arm cannot both descend into an object and decode a value.
    @Test("a group's first segment colliding with a declared key is refused")
    func collision() {
        let (_, diags) = expandSchemaForTesting("""
            @Schema struct S {
                var profile: String
                @Key(path: "profile.name") var name: String
            }
            """)
        #expect(diags.contains { $0.contains("profile") }, "got \(diags)")
    }
}

// MARK: - YAML and XML

@Schema(formats: .all)
struct RawCard: Equatable {
    @Key(path: "profile.name") var name: String
    @Key(path: "profile.avatar") var avatar: String?
    @Key(path: "meta.stats.views") var views: Int = 0
    var id: String
}

@Suite("@Key(path:) — the tree paths")
struct KeyPathRawTests {

    @Test("a path walks a YAML mapping")
    func yaml() throws {
        let c = try RawCard.parse(yaml: """
            id: x
            profile:
              name: Ada
              avatar: a.png
            meta:
              stats:
                views: 5
            """)
        #expect(c == RawCard(name: "Ada", avatar: "a.png", views: 5, id: "x"))
    }

    /// **The rule that must not vary by format.** A schema whose missing-intermediate report
    /// depended on whether the bytes were JSON or YAML would be two features wearing one name.
    @Test("YAML reports a missing intermediate exactly as JSON does")
    func yamlMissingIntermediate() {
        let j = RawCard.diagnose(json: #"{"id":"x"}"#)
        let y = RawCard.diagnose(yaml: "id: x\n")
        #expect(j.issues.map(\.path.pathDescription) == ["profile"])
        #expect(y.issues.map(\.path.pathDescription) == j.issues.map(\.path.pathDescription))
        #expect(y.issues.first?.code == j.issues.first?.code)
    }

    @Test("YAML reports a missing leaf exactly as JSON does")
    func yamlMissingLeaf() {
        let j = RawCard.diagnose(json: #"{"id":"x","profile":{}}"#)
        let y = RawCard.diagnose(yaml: "id: x\nprofile: {}\n")
        #expect(j.issues.map(\.path.pathDescription) == ["profile.name"])
        #expect(y.issues.map(\.path.pathDescription) == j.issues.map(\.path.pathDescription))
    }

    @Test("YAML reports a wrong-typed intermediate exactly as JSON does")
    func yamlWrongType() {
        let j = RawCard.diagnose(json: #"{"id":"x","profile":42}"#)
        let y = RawCard.diagnose(yaml: "id: x\nprofile: 42\n")
        #expect(j.issues.first?.code == .typeMismatch)
        #expect(y.issues.first?.code == .typeMismatch)
        #expect(y.issues.first?.path.pathDescription == "profile")
    }

    @Test("a path walks XML nesting")
    func xml() throws {
        let c = try RawCard.parse(xml: """
            <card><id>x</id><profile><name>Ada</name></profile></card>
            """)
        #expect(c.name == "Ada")
        #expect(c.id == "x")
    }
}

// MARK: - Encoding

@Schema(formats: .all, encodes: true)
struct EncCard: Equatable {
    @Key(path: "profile.name") var name: String
    @Key(path: "profile.avatar") var avatar: String?
    @Key(path: "meta.stats.views") var views: Int
    var id: String
}

@Suite("@Key(path:) — encoding")
struct KeyPathEncodeTests {

    /// **The law `docs/ENCODING.md` states.** Two fields sharing a prefix must merge into one
    /// object, not two dotted keys — `{"profile.name": ...}` is a document this schema cannot
    /// read back, which would break round-trip for every path field at once.
    @Test("two paths under one prefix encode as one nested object")
    func merged() throws {
        let c = EncCard(name: "Ada", avatar: "a.png", views: 3, id: "x")
        let text = String(decoding: try c.encodedJSON(), as: UTF8.self)
        #expect(text.contains(#""profile":{"#), "got \(text)")
        #expect(!text.contains("profile.name"), "a dotted key does not round-trip: \(text)")
        #expect(text.contains(#""meta":{"stats":{"views":3}}"#), "got \(text)")
    }

    @Test("round-trip through JSON")
    func roundTripJSON() throws {
        let c = EncCard(name: "Ada", avatar: nil, views: 7, id: "x")
        #expect(try EncCard.parse(json: Array(c.encodedJSON())) == c)
    }

    @Test("round-trip through YAML")
    func roundTripYAML() throws {
        let c = EncCard(name: "Ada", avatar: "a.png", views: 0, id: "x")
        #expect(try EncCard.parse(yaml: c.encodedYAML()) == c)
    }
}

@Suite("@Key(path:) — the expansion itself")
struct KeyPathExpansion {

    /// **A compile-time regression with no runtime symptom, so only this can catch it.**
    ///
    /// The sparse key-table emitter writes every entry that differs from a sentinel, and the
    /// sentinel is the number of dispatch ARMS. That stops equalling the number of FIELDS the
    /// moment two fields share a path prefix — and when it was wrong, the expansion carried a
    /// **253-assignment array literal**, which is the exact cost `COMPILE-TIME.md` rule 1
    /// exists to prevent. Every decode still produced the right answer and every test passed.
    ///
    /// Found by reading a dumped expansion. Nothing else would have found it, which is why
    /// this asserts on the expansion rather than on behaviour.
    @Test("a path schema emits a SPARSE key table, not 253 assignments")
    func keyTableStaysSparse() {
        let (expansion, diags) = expandSchemaForTesting("""
            @Schema struct S {
                @Key(path: "profile.display_name") var displayName: String
                @Key(path: "profile.avatar") var avatar: String?
                @Key(path: "meta.stats.views") var views: Int
                var id: String
            }
            """)
        #expect(diags.isEmpty, "\(diags)")

        // Four fields, but only THREE top-level arms — `profile` and `meta` are one each,
        // shared by the fields beneath them.
        let assignments = expansion.components(separatedBy: "t[").count - 1
        #expect(assignments <= 8, """
                the key table has \(assignments) assignments. It should have one per distinct \
                window value — a handful. A number near 253 means the sentinel does not match \
                the arm count and every entry is being written out.
                """)
        #expect(expansion.contains("repeating: 3"), """
                the sentinel should be the ARM count (3: one plain field plus two path \
                groups), not the field count (4).
                """)
    }
}
