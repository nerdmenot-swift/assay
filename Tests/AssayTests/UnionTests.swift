// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Discriminated unions, built 2026-09-09. `docs/UNIONS.md`, EXPERIENCE §9, ROADMAP §5.
//
// The load-bearing suite is `UnionErrors`. `EXPERIENCE.md` §9's entire argument for preferring
// a discriminator is about failure reporting:
//
//   > `{"type": "click", ...}` picks the branch by the discriminator alone, so a malformed
//   > click event reports as a malformed click event — not as "did not match any of 3
//   > variants" followed by three sets of irrelevant errors. That failure mode is the single
//   > most-complained-about thing in every validation library that has union types.
//
// So the tests that matter are not "does it decode" but "when it fails, does it blame the
// right thing exactly once". `malformedBranchBlamesTheBranch` is the one that would catch a
// regression into the wall of noise.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayCore

@Schema(keys: .snakeCase)
struct UnionClick: Equatable {
    var x: Int
    var y: Int
}

@Schema(keys: .snakeCase)
struct UnionPageView: Equatable {
    var url: String
    var referrer: String?
}

@Schema(keys: .snakeCase, discriminator: "type")
enum UnionEvent: Equatable {
    case click(UnionClick)
    case pageView(UnionPageView)
}

/// `@Key` on a case overrides the tag spelling, as it does for a field.
@Schema(discriminator: "kind")
enum UnionShape: Equatable {
    @Key("circular") case circle(UnionClick)
    case square(UnionClick)
}

/// A union as a FIELD, which is the shape every real API actually has.
@Schema(keys: .snakeCase)
struct UnionEnvelope: Equatable {
    var id: String
    var payload: UnionEvent
}

@Schema
struct UnionBatch: Equatable { var events: [UnionEvent] }

@Suite("discriminated unions")
struct UnionTests {

    @Test("the tag picks the branch")
    func picksBranch() throws {
        let a = try UnionEvent.parse(json: #"{"type":"click","x":1,"y":2}"#)
        #expect(a == .click(UnionClick(x: 1, y: 2)))
        let b = try UnionEvent.parse(json: #"{"type":"page_view","url":"/home"}"#)
        #expect(b == .pageView(UnionPageView(url: "/home", referrer: nil)))
    }

    /// **The case that forces the pre-scan.** `{"a":1,"type":"click"}` is a legal document, so
    /// the branch cannot be chosen by reading forward.
    @Test("the tag may arrive last")
    func tagLast() throws {
        let a = try UnionEvent.parse(json: #"{"x":1,"y":2,"type":"click"}"#)
        #expect(a == .click(UnionClick(x: 1, y: 2)))
    }

    @Test("the tag may arrive in the middle, after a nested object")
    func tagAfterNesting() throws {
        // The pre-scan must skip a whole nested value structurally to reach the tag.
        let a = try UnionEvent.parse(json: #"""
            {"x":1,"ignored":{"deep":[1,2,{"deeper":true}]},"type":"click","y":2}
            """#)
        #expect(a == .click(UnionClick(x: 1, y: 2)))
    }

    @Test("a case's tag spelling follows keys:, and @Key overrides it")
    func tagSpelling() throws {
        #expect(try UnionEvent.parse(json: #"{"type":"page_view","url":"/"}"#)
                == .pageView(UnionPageView(url: "/", referrer: nil)))
        #expect(try UnionShape.parse(json: #"{"kind":"circular","x":1,"y":2}"#)
                == .circle(UnionClick(x: 1, y: 2)))
        #expect(try UnionShape.parse(json: #"{"kind":"square","x":1,"y":2}"#)
                == .square(UnionClick(x: 1, y: 2)))
    }

    /// The variant sees the whole object, tag included — `docs/UNIONS.md` §5. Under the
    /// default `unknownKeys: .ignore` that is invisible, which is what this pins.
    @Test("the tag reaches the variant and is ignored by default")
    func tagReachesVariant() throws {
        let a = try UnionEvent.parse(json: #"{"type":"click","x":1,"y":2}"#)
        #expect(a == .click(UnionClick(x: 1, y: 2)))
    }

    @Test("a union works as a field of a struct")
    func asField() throws {
        let e = try UnionEnvelope.parse(json: #"""
            {"id":"e1","payload":{"type":"click","x":3,"y":4}}
            """#)
        #expect(e == UnionEnvelope(id: "e1", payload: .click(UnionClick(x: 3, y: 4))))
    }

    @Test("a union works in an array")
    func inArray() throws {
        let b = try UnionBatch.parse(json: #"""
            {"events":[{"type":"click","x":1,"y":2},{"type":"page_view","url":"/a"}]}
            """#)
        #expect(b.events.count == 2)
        #expect(b.events[0] == .click(UnionClick(x: 1, y: 2)))
        #expect(b.events[1] == .pageView(UnionPageView(url: "/a", referrer: nil)))
    }
}

@Suite("discriminated unions — what failure looks like")
struct UnionErrors {

    /// **The load-bearing test, and the reason to prefer a discriminator at all.** Once the tag
    /// is read exactly one branch is possible, so its issues *are* the union's issues: one
    /// error, naming the real field, with no mention of the branches that were never tried.
    @Test("a malformed branch reports as that branch, once")
    func malformedBranchBlamesTheBranch() {
        let d = UnionEvent.diagnose(json: #"{"type":"click","x":"nope","y":2}"#)
        #expect(!d.isValid)
        #expect(d.issues.count == 1, """
                a discriminated union must report the chosen branch's failure and nothing \\
                else. Got \\(d.issues.map { "\\($0.code) at \\($0.path.pathDescription)" })
                """)
        #expect(d.issues.first?.code == .typeMismatch)
        #expect(d.issues.first?.path.pathDescription == "x")
        // And nothing about page_view, which was never a candidate.
        #expect(!d.issues.contains { $0.message.contains("url") })
    }

    @Test("a missing field inside the chosen branch reports as that field")
    func missingInBranch() {
        let d = UnionEvent.diagnose(json: #"{"type":"click","x":1}"#)
        #expect(d.issues.count == 1)
        #expect(d.issues.first?.code == .missing)
        #expect(d.issues.first?.path.pathDescription == "y")
    }

    @Test("an absent tag is one missing-key issue, not a branch failure")
    func missingTag() {
        let d = UnionEvent.diagnose(json: #"{"x":1,"y":2}"#)
        #expect(d.issues.count == 1, "\(d.issues.map { "\($0.code) at \($0.path.pathDescription)" })")
        #expect(d.issues.first?.code == .missing)
        #expect(d.issues.first?.path.pathDescription == "type")
    }

    /// An unrecognised tag gets a did-you-mean, from the same machinery unknown keys use —
    /// `"pageview"` for `"page_view"` is how this fails in practice.
    @Test("an unrecognised tag is one issue, with a did-you-mean")
    func unknownVariant() {
        let d = UnionEvent.diagnose(json: #"{"type":"pageview","url":"/"}"#)
        #expect(d.issues.count == 1)
        #expect(d.issues.first?.code == .custom("union_unknown_variant"))
        #expect(d.issues.first?.params["didYouMean"] == .string("page_view"),
                "got \(String(describing: d.issues.first?.params))")
        #expect(d.issues.first?.params["known"] == .string("click, page_view"))
    }

    @Test("a tag that resembles nothing gets no suggestion rather than a wrong one")
    func noSuggestion() {
        let d = UnionEvent.diagnose(json: #"{"type":"zzzzzzz"}"#)
        #expect(d.issues.first?.code == .custom("union_unknown_variant"))
        #expect(d.issues.first?.params["didYouMean"] == nil)
    }

    /// The tag exists and is not a string. No branch could have been chosen, so no branch is
    /// blamed.
    @Test("a non-string tag is the union's failure, not a branch's")
    func nonStringTag() {
        let d = UnionEvent.diagnose(json: #"{"type":42,"x":1,"y":2}"#)
        #expect(!d.isValid)
        #expect(d.issues.count == 1)
        #expect(d.issues.first?.code == .typeMismatch)
        #expect(d.issues.first?.path.pathDescription == "type")
    }

    @Test("a non-object where a union was declared is a type mismatch")
    func notAnObject() {
        let d = UnionEvent.diagnose(json: #"[1,2,3]"#)
        #expect(!d.isValid)
        #expect(d.issues.first?.code == .typeMismatch)
    }

    /// A union inside a struct reports at the field's path, not at the root.
    @Test("a nested union's issues carry the outer path")
    func nestedPath() {
        let d = UnionEnvelope.diagnose(json: #"""
            {"id":"e","payload":{"type":"click","x":"nope","y":1}}
            """#)
        #expect(d.issues.count == 1)
        #expect(d.issues.first?.path.pathDescription == "payload.x",
                "got \(d.issues.first?.path.pathDescription ?? "nil")")
    }

    /// An unrecognised variant must still leave the reader able to finish the document — the
    /// union skips the value it could not decode rather than abandoning the parse mid-object.
    @Test("an unrecognised variant does not derail the rest of the document")
    func unknownVariantResynchronises() {
        let d = UnionEnvelope.diagnose(json: #"""
            {"payload":{"type":"nope","x":1},"id":"e"}
            """#)
        // One issue about the variant; `id` still decoded, so no second issue about it.
        #expect(d.issues.count == 1, "\(d.issues.map { "\($0.code)" })")
        #expect(d.issues.first?.code == .custom("union_unknown_variant"))
    }
}

@Suite("discriminated unions — expansion-time refusals")
struct UnionDiagnostics {

    /// Untagged unions are designed (`docs/UNIONS.md`) and not built. The diagnostic says so
    /// and says why, rather than "unsupported".
    @Test("discriminator: .none is refused, with the reason")
    func untaggedRefused() {
        let (_, diags) = expandSchemaForTesting("""
            @Schema(discriminator: .none) enum U { case a(A); case b(B) }
            """)
        #expect(diags.contains { $0.contains("untagged unions") && $0.contains("docs/UNIONS.md") },
                "got \(diags)")
    }

    @Test("a case with no payload is refused")
    func noPayload() {
        let (_, diags) = expandSchemaForTesting("""
            @Schema(discriminator: "type") enum U { case a(A); case b }
            """)
        #expect(diags.contains { $0.contains("exactly one associated value") }, "got \(diags)")
    }

    /// Two cases sharing a tag spelling would make the second unreachable, silently.
    @Test("two cases with the same tag are refused")
    func duplicateTag() {
        let (_, diags) = expandSchemaForTesting("""
            @Schema(discriminator: "type") enum U {
                case a(A)
                @Key("a") case b(B)
            }
            """)
        #expect(diags.contains { $0.contains("can never be chosen") }, "got \(diags)")
    }

    @Test("@Unknown on a union case is refused")
    func unknownCase() {
        let (_, diags) = expandSchemaForTesting("""
            @Schema(discriminator: "type") enum U {
                case a(A)
                @Unknown case other(String)
            }
            """)
        #expect(diags.contains { $0.contains("catch-all") }, "got \(diags)")
    }

    /// YAML and XML go through `RawValue`, which the union path does not implement.
    @Test("formats other than JSON are refused rather than silently omitted")
    func rawFormatsRefused() {
        let (_, diags) = expandSchemaForTesting("""
            @Schema(formats: .yaml, discriminator: "type") enum U { case a(A) }
            """)
        #expect(diags.contains { $0.contains("RawValue path") }, "got \(diags)")
    }
}

extension UnionDiagnostics {

    /// `encodes: true` emits no encoder for a union, and a silently-ignored option is worse
    /// than a refused one. `docs/UNIONS.md` §4 settles what it should mean.
    @Test("encodes: true on a union is refused rather than ignored")
    func encodingRefused() {
        let (_, diags) = expandSchemaForTesting("""
            @Schema(discriminator: "type", encodes: true) enum U { case a(A) }
            """)
        #expect(diags.contains { $0.contains("not built for unions") }, "got \(diags)")
    }
}
