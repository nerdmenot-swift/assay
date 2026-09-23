// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Discriminated unions — what failure looks like, and what the macro refuses.
//
// The load-bearing suite. `EXPERIENCE.md` §9's entire argument for preferring a
// discriminator is about failure reporting: a malformed click event reports as a malformed
// click event, not as "did not match any of 3 variants" followed by three sets of
// irrelevant errors. `malformedBranchBlamesTheBranch` is the test that would catch a
// regression into that wall of noise. Fixtures are in UnionTests.swift.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayCore

@Suite("discriminated unions — what failure looks like")
struct UnionErrors {

    /// **The load-bearing test, and the reason to prefer a discriminator at all.** Once the tag
    /// is read exactly one branch is possible, so its issues *are* the union's issues: one
    /// error, naming the real field, with no mention of the branches that were never tried.
    @Test("a malformed branch reports as that branch, once")
    func malformedBranchBlamesTheBranch() {
        let d = UnionEvent.diagnose(json: #"{"type":"click","x":"nope","y":2}"#)
        #expect(!d.isValid)
        #expect(
            d.issues.count == 1,
            """
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
        #expect(
            d.issues.count == 1, "\(d.issues.map { "\($0.code) at \($0.path.pathDescription)" })")
        #expect(d.issues.first?.code == .missing)
        #expect(d.issues.first?.path.pathDescription == "type")
    }

    /// An unrecognised tag gets a did-you-mean, from the same machinery unknown keys use —
    /// `"pageview"` for `"page_view"` is how this fails in practice.
    @Test("an unrecognised tag is one issue, with a did-you-mean")
    func _unknownVariant() {
        let d = UnionEvent.diagnose(json: #"{"type":"pageview","url":"/"}"#)
        #expect(d.issues.count == 1)
        #expect(d.issues.first?.code == .unionUnknownVariant)
        #expect(
            d.issues.first?.params["didYouMean"] == .string("page_view"),
            "got \(String(describing: d.issues.first?.params))")
        #expect(d.issues.first?.params["known"] == .string("click, page_view"))
    }

    @Test("a tag that resembles nothing gets no suggestion rather than a wrong one")
    func noSuggestion() {
        let d = UnionEvent.diagnose(json: #"{"type":"zzzzzzz"}"#)
        #expect(d.issues.first?.code == .unionUnknownVariant)
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
    func _notAnObject() {
        let d = UnionEvent.diagnose(json: #"[1,2,3]"#)
        #expect(!d.isValid)
        #expect(d.issues.first?.code == .typeMismatch)
    }

    /// A union inside a struct reports at the field's path, not at the root.
    @Test("a nested union's issues carry the outer path")
    func nestedPath() {
        let d = UnionEnvelope.diagnose(
            json: #"""
                {"id":"e","payload":{"type":"click","x":"nope","y":1}}
                """#)
        #expect(d.issues.count == 1)
        #expect(
            d.issues.first?.path.pathDescription == "payload.x",
            "got \(d.issues.first?.path.pathDescription ?? "nil")")
    }

    /// An unrecognised variant must still leave the reader able to finish the document — the
    /// union skips the value it could not decode rather than abandoning the parse mid-object.
    @Test("an unrecognised variant does not derail the rest of the document")
    func unknownVariantResynchronises() {
        let d = UnionEnvelope.diagnose(
            json: #"""
                {"payload":{"type":"nope","x":1},"id":"e"}
                """#)
        // One issue about the variant; `id` still decoded, so no second issue about it.
        #expect(d.issues.count == 1, "\(d.issues.map { "\($0.code)" })")
        #expect(d.issues.first?.code == .unionUnknownVariant)
    }
}

@Suite("discriminated unions — expansion-time refusals")
struct UnionDiagnostics {

    /// `docs/UNIONS.md` §4: two cases carrying the SAME payload type make the second
    /// unreachable and break round-trip — `.b(1)` encodes as `1` and decodes as `.a(1)`. It is
    /// the one union check a macro can do without a conformance lookup.
    @Test("two untagged cases with the same payload type are refused")
    func duplicatePayloadRefused() {
        let (_, diags) = expandSchemaForTesting(
            """
            @Schema(discriminator: .untagged) enum U { case a(Int); case b(Int) }
            """)
        #expect(diags.contains { $0.contains("both carry a 'Int'") }, "got \(diags)")
    }

    /// What the macro CANNOT see, recorded so the limit is known: two distinct types that
    /// accept the same documents. The tokens differ, so expansion cannot refuse it — the first
    /// branch wins and the second never round-trips. `docs/UNIONS.md` §4's stated exception.
    @Test("two distinct types that accept the same documents are NOT refused")
    func indistinguishableTypesNotRefused() {
        let (_, diags) = expandSchemaForTesting(
            """
            @Schema(discriminator: .untagged) enum U { case a(P); case b(Q) }
            """)
        #expect(diags.isEmpty, "a macro sees tokens, not conformances: \(diags)")
    }

    @Test("a case with no payload is refused")
    func noPayload() {
        let (_, diags) = expandSchemaForTesting(
            """
            @Schema(discriminator: "type") enum U { case a(A); case b }
            """)
        #expect(diags.contains { $0.contains("exactly one associated value") }, "got \(diags)")
    }

    /// Two cases sharing a tag spelling would make the second unreachable, silently.
    @Test("two cases with the same tag are refused")
    func duplicateTag() {
        let (_, diags) = expandSchemaForTesting(
            """
            @Schema(discriminator: "type") enum U {
                case a(A)
                @Key("a") case b(B)
            }
            """)
        #expect(diags.contains { $0.contains("can never be chosen") }, "got \(diags)")
    }

    @Test("@Unknown on a union case is refused")
    func unknownCase() {
        let (_, diags) = expandSchemaForTesting(
            """
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
        let (_, diags) = expandSchemaForTesting(
            """
            @Schema(formats: .yaml, discriminator: "type") enum U { case a(A) }
            """)
        #expect(diags.contains { $0.contains("RawValue path") }, "got \(diags)")
    }
}

extension UnionDiagnostics {

    /// `formats: .all` sets the RawValue bit *and* the JSON one, so a guard that tested only
    /// `formats.json` let it through and emitted a JSON-only body — a union that decoded from
    /// JSON and not from YAML while declaring `.all`, which is the exact trap the refusal
    /// above exists to prevent. Found while building encoding; fixed 2026-09-10.
    /// Two options a union does not implement, refused rather than accepted and ignored.
    /// `context:` is the one that needs a refusal most: the other eventually produces a
    /// type-checker error at the call site of a member that was never emitted, while a
    /// contextual union would simply stay non-contextual — `parse(json:)` resolves, nothing
    /// errors, and the context never reaches a check.
    @Test("describes: and context: are refused on a union")
    func ignoredOptionsRefused() {
        let (_, describes) = expandSchemaForTesting(
            """
            @Schema(describes: true, discriminator: "type") enum U { case a(A) }
            """)
        #expect(describes.contains { $0.contains("not built for unions") }, "got \(describes)")

        let (_, ctx) = expandSchemaForTesting(
            """
            @Schema(context: Ctx.self, discriminator: "type") enum U { case a(A) }
            """)
        #expect(ctx.contains { $0.contains("non-contextual") }, "got \(ctx)")
    }

    @Test("formats: .all is refused, not silently narrowed to JSON")
    func allFormatsRefused() {
        let (_, diags) = expandSchemaForTesting(
            """
            @Schema(formats: .all, discriminator: "type") enum U { case a(A) }
            """)
        #expect(diags.contains { $0.contains("RawValue path") }, "got \(diags)")
    }
}
