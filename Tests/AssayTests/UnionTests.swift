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

    /// `docs/UNIONS.md` §4: two cases carrying the SAME payload type make the second
    /// unreachable and break round-trip — `.b(1)` encodes as `1` and decodes as `.a(1)`. It is
    /// the one union check a macro can do without a conformance lookup.
    @Test("two untagged cases with the same payload type are refused")
    func duplicatePayloadRefused() {
        let (_, diags) = expandSchemaForTesting("""
            @Schema(discriminator: .untagged) enum U { case a(Int); case b(Int) }
            """)
        #expect(diags.contains { $0.contains("both carry a 'Int'") }, "got \(diags)")
    }

    /// What the macro CANNOT see, recorded so the limit is known: two distinct types that
    /// accept the same documents. The tokens differ, so expansion cannot refuse it — the first
    /// branch wins and the second never round-trips. `docs/UNIONS.md` §4's stated exception.
    @Test("two distinct types that accept the same documents are NOT refused")
    func indistinguishableTypesNotRefused() {
        let (_, diags) = expandSchemaForTesting("""
            @Schema(discriminator: .untagged) enum U { case a(P); case b(Q) }
            """)
        #expect(diags.isEmpty, "a macro sees tokens, not conformances: \(diags)")
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

    /// `formats: .all` sets the RawValue bit *and* the JSON one, so a guard that tested only
    /// `formats.json` let it through and emitted a JSON-only body — a union that decoded from
    /// JSON and not from YAML while declaring `.all`, which is the exact trap the refusal
    /// above exists to prevent. Found while building encoding; fixed 2026-09-10.
    /// Three options a union does not implement, refused rather than accepted and ignored.
    /// `context:` is the one that needs a refusal most: the other two eventually produce a
    /// type-checker error at the call site of a member that was never emitted, while a
    /// contextual union would simply stay non-contextual — `parse(json:)` resolves, nothing
    /// errors, and the context never reaches a check.
    @Test("sources:, describes: and context: are refused on a union")
    func ignoredOptionsRefused() {
        let (_, sources) = expandSchemaForTesting("""
            @Schema(sources: true, discriminator: "type") enum U { case a(A) }
            """)
        #expect(sources.contains { $0.contains("column-first source") }, "got \(sources)")

        let (_, describes) = expandSchemaForTesting("""
            @Schema(describes: true, discriminator: "type") enum U { case a(A) }
            """)
        #expect(describes.contains { $0.contains("not built for unions") }, "got \(describes)")

        let (_, ctx) = expandSchemaForTesting("""
            @Schema(context: Ctx.self, discriminator: "type") enum U { case a(A) }
            """)
        #expect(ctx.contains { $0.contains("non-contextual") }, "got \(ctx)")
    }

    @Test("formats: .all is refused, not silently narrowed to JSON")
    func allFormatsRefused() {
        let (_, diags) = expandSchemaForTesting("""
            @Schema(formats: .all, discriminator: "type") enum U { case a(A) }
            """)
        #expect(diags.contains { $0.contains("RawValue path") }, "got \(diags)")
    }
}

// MARK: - Untagged unions
//
// `docs/UNIONS.md` §§2.2 and 3. Everything a tagged union does not have to answer: which
// branch to blame when they all fail, and what stops nested unions from going exponential.

@Schema(discriminator: .untagged)
enum StringOrNumber: Equatable {
    case text(String)
    case number(Double)
}

@Schema(keys: .snakeCase)
struct UntaggedPoint: Equatable { var x: Int; var y: Int }

@Schema(keys: .snakeCase)
struct UntaggedLine: Equatable { var from: String; var to: String; var width: Int }

/// Two struct branches, so "which one came closest" has a meaningful answer.
@Schema(discriminator: .untagged)
enum Figure: Equatable {
    case point(UntaggedPoint)
    case line(UntaggedLine)
}

@Schema
struct FigureHolder: Equatable { var figure: Figure }

@Schema
struct FigurePair: Equatable { var figure: Figure; var name: String }

@Schema
struct FigureMany: Equatable { var figures: [Figure] }

@Suite("untagged unions")
struct UntaggedUnionTests {

    @Test("the first branch that decodes wins, in declaration order")
    func firstMatchWins() throws {
        #expect(try StringOrNumber.parse(json: #""hello""#) == .text("hello"))
        #expect(try StringOrNumber.parse(json: #"42.5"#) == .number(42.5))
    }

    @Test("struct branches are distinguished by shape")
    func structBranches() throws {
        #expect(try Figure.parse(json: #"{"x":1,"y":2}"#) == .point(UntaggedPoint(x: 1, y: 2)))
        #expect(try Figure.parse(json: #"{"from":"a","to":"b","width":3}"#)
                == .line(UntaggedLine(from: "a", to: "b", width: 3)))
    }

    @Test("an untagged union works as a field")
    func asField() throws {
        let h = try FigureHolder.parse(json: #"{"figure":{"x":1,"y":2}}"#)
        #expect(h == FigureHolder(figure: .point(UntaggedPoint(x: 1, y: 2))))
    }

    /// A successful branch must leave nothing behind from the branches that failed first.
    @Test("issues from earlier failed branches are discarded on success")
    func earlierFailuresDiscarded() {
        let d = StringOrNumber.diagnose(json: #"42.5"#)
        #expect(d.isValid)
        #expect(d.issues.isEmpty, "\(d.issues.map { "\($0.code)" })")
    }
}

@Suite("untagged unions — the composed failure")
struct UntaggedUnionErrors {

    /// **`docs/UNIONS.md` §2.2's rule.** One summary naming the guess as a guess, plus the
    /// detail of exactly one branch — not the wall of noise, and not a bare "no match".
    @Test("one summary plus the closest branch's detail")
    func summaryPlusClosest() {
        // Shaped like a point with one bad field: `point` should be closer than `line`, which
        // is missing three fields.
        let d = Figure.diagnose(json: #"{"x":1,"y":"nope"}"#)
        #expect(!d.isValid)

        let summary = d.issues.first { $0.code == .custom("union_no_variant_matched") }
        #expect(summary != nil, "\(d.issues.map { "\($0.code)" })")
        #expect(summary?.params["closest"] == .string("point"),
                "got \(String(describing: summary?.params["closest"]))")
        #expect(summary?.params["variants"] == .string("point, line"))

        // And the closest branch's detail follows it — the `y` field, not `line`'s fields.
        #expect(d.issues.contains { $0.path.pathDescription == "y" },
                "\(d.issues.map { "\($0.code) at \($0.path.pathDescription)" })")
        #expect(!d.issues.contains { $0.path.pathDescription == "width" },
                "the branch that was not closest must not be reported")
    }

    @Test("the summary names the type and every variant")
    func summaryNamesEverything() {
        let d = StringOrNumber.diagnose(json: #"{"a":1}"#)
        let summary = d.issues.first { $0.code == .custom("union_no_variant_matched") }
        #expect(summary?.params["type"] == .string("StringOrNumber"))
        #expect(summary?.params["variants"] == .string("text, number"))
    }

    /// verboseUnions is the escape hatch for a wire format you do not control.
    @Test("verboseUnions reports every branch instead of one")
    func verbose() {
        var limits = Limits.default
        limits.verboseUnions = true
        let quiet = Figure.diagnose(json: #"{"x":1,"y":"nope"}"#)
        let loud = Figure.diagnose(json: #"{"x":1,"y":"nope"}"#, limits: limits)
        #expect(loud.issues.count > quiet.issues.count, """
                verbose mode must add the branches the summary left out — \\
                quiet=\(quiet.issues.count) loud=\(loud.issues.count)
                """)
        #expect(loud.issues.contains { $0.path.pathDescription == "width" },
                "the branch that was not closest should appear in verbose mode")
    }

    /// A failed union inside a struct must not derail the rest of the document.
    @Test("a failed union resynchronises")
    func resynchronises() {
        let d = FigurePair.diagnose(json: #"{"figure":{"zzz":1},"name":"ok"}"#)
        // The union's issues, and nothing about `name`, which decoded fine.
        #expect(!d.isValid)
        #expect(!d.issues.contains { $0.path.pathDescription == "name" },
                "\(d.issues.map { "\($0.code) at \($0.path.pathDescription)" })")
    }
}

@Suite("untagged unions — the backtracking budget")
struct UntaggedUnionBudget {

    /// **`docs/UNIONS.md` §3.** The exponential is *nested* unions, and `maxDepth` cannot see
    /// it — the depth is the array nesting and the blow-up is in the breadth. A budget of ten
    /// against a document that needs more must be refused rather than explored.
    @Test("a low budget is enforced and reported")
    func budgetEnforced() {
        var limits = Limits.default
        // ONE attempt. A failing element aborts the enclosing array — `arrayDecode` breaks on
        // the first element that will not decode — so a union-heavy document does not make
        // very many attempts before it stops. A budget above two is never reached here, which
        // is what the first version of this test got wrong.
        limits.maxUnionAttempts = 1

        let doc = #"{"figures":[{"z":1},{"z":1},{"z":1}]}"#
        let d = FigureMany.diagnose(json: doc, limits: limits)
        #expect(!d.isValid)
        #expect(d.issues.contains { $0.code == .custom("union_budget_exhausted") },
                "\(d.issues.map { "\($0.code)" })")
    }

    /// The budget must not be refunded by a rewind, or it bounds nothing.
    @Test("rewinding does not refund attempts")
    func rewindDoesNotRefund() {
        var limits = Limits.default
        limits.maxUnionAttempts = 1
        // The failure path rewinds the reader repeatedly — once per branch, and again for the
        // replay. If any of those refunded the counter, one attempt would never be exceeded.
        let doc = #"{"figures":[{"z":1}]}"#
        let d = FigureMany.diagnose(json: doc, limits: limits)
        #expect(d.issues.contains { $0.code == .custom("union_budget_exhausted") },
                "\(d.issues.map { "\($0.code)" })")
    }

    /// The default is far above any real document, so ordinary use never sees it.
    @Test("the default budget does not fire on an ordinary document")
    func defaultBudgetIsGenerous() throws {
        var doc = #"{"figures":["#
        for i in 0..<200 {
            if i > 0 { doc += "," }
            doc += #"{"from":"a","to":"b","width":1}"#     // always the SECOND branch
        }
        doc += "]}"
        let v = try FigureMany.parse(json: doc)
        #expect(v.figures.count == 200)
    }
}

// MARK: - Encoding
//
// `docs/UNIONS.md` §4, built 2026-09-10. The section was written as "the settled answer for
// when it is built", and these are its four claims turned into assertions: the tagged form
// writes the payload plus the tag, the tag is the case name through `keys:`, the untagged
// form writes the payload alone, and round-trip holds except where §4 says it cannot.

@Schema(keys: .snakeCase, encodes: true)
struct EncClick: Equatable { var x: Int; var y: Int }

@Schema(keys: .snakeCase, encodes: true)
struct EncPageView: Equatable { var url: String; var referrer: String? }

@Schema(keys: .snakeCase, encodes: true, discriminator: "type")
enum EncEvent: Equatable {
    case click(EncClick)
    case pageView(EncPageView)
}

/// `@Key` overrides the tag spelling on the way out as well as on the way in — one stored
/// `wireName`, so the two sides cannot drift.
@Schema(encodes: true, discriminator: "kind")
enum EncShape: Equatable {
    @Key("circular") case circle(EncClick)
    case square(EncClick)
}

@Schema(keys: .snakeCase, encodes: true)
struct EncEnvelope: Equatable {
    var id: String
    var payload: EncEvent
}

@Schema(encodes: true)
struct EncBatch: Equatable { var events: [EncEvent] }

/// A union whose variant is itself a union. This is what `_assayEncodeMembers` buys: the
/// outer union opens the object and writes its tag, the inner one writes its own tag and the
/// payload's members into that same object.
@Schema(encodes: true, discriminator: "sub")
enum EncInner: Equatable { case click(EncClick) }

@Schema(encodes: true, discriminator: "type")
enum EncOuter: Equatable { case inner(EncInner) }

/// `docs/UNIONS.md` §5: the tag key reaches the variant, and a variant may declare it. Then
/// encoding writes the key twice — the union's tag and the variant's own field.
@Schema(encodes: true)
struct EncTagCarrier: Equatable { var type: String; var x: Int }

@Schema(encodes: true, discriminator: "type")
enum EncCarrying: Equatable { case carrier(EncTagCarrier) }

@Suite("unions — encoding")
struct UnionEncodingTests {

    @Test("the tagged form writes the payload's object with the tag added, tag first")
    func taggedWritesTagFirst() throws {
        let text = try EncEvent.click(EncClick(x: 1, y: 2)).jsonText()
        #expect(text == #"{"type":"click","x":1,"y":2}"#)
    }

    /// The tag is the CASE name through the type's `keys:` style — the same rule field names
    /// follow, rather than a second convention to remember.
    @Test("the tag is the case name through keys:")
    func tagFollowsKeyStyle() throws {
        let text = try EncEvent.pageView(EncPageView(url: "/home", referrer: nil)).jsonText()
        #expect(text == #"{"type":"page_view","url":"/home","referrer":null}"#)
    }

    @Test("@Key on a case overrides the tag on the way out")
    func keyOverride() throws {
        #expect(try EncShape.circle(EncClick(x: 0, y: 0)).jsonText()
                == #"{"kind":"circular","x":0,"y":0}"#)
        #expect(try EncShape.square(EncClick(x: 0, y: 0)).jsonText()
                == #"{"kind":"square","x":0,"y":0}"#)
    }

    @Test("round trip: tagged")
    func taggedRoundTrip() throws {
        for value in [EncEvent.click(EncClick(x: 3, y: 4)),
                      .pageView(EncPageView(url: "/a", referrer: "/b"))] {
            #expect(try EncEvent.parse(json: value.encodedJSON()) == value)
        }
    }

    @Test("a union as a field, and as an array element")
    func nestedInStructs() throws {
        let e = EncEnvelope(id: "e1", payload: .click(EncClick(x: 1, y: 2)))
        #expect(try e.jsonText() == #"{"id":"e1","payload":{"type":"click","x":1,"y":2}}"#)
        #expect(try EncEnvelope.parse(json: e.encodedJSON()) == e)

        let b = EncBatch(events: [.click(EncClick(x: 1, y: 2)),
                                  .pageView(EncPageView(url: "/z", referrer: nil))])
        #expect(try EncBatch.parse(json: b.encodedJSON()) == b)
    }

    @Test("a union inside a union writes one object with both tags")
    func unionInsideUnion() throws {
        let v = EncOuter.inner(.click(EncClick(x: 7, y: 8)))
        #expect(try v.jsonText() == #"{"type":"inner","sub":"click","x":7,"y":8}"#)
        #expect(try EncOuter.parse(json: v.encodedJSON()) == v)
    }

    /// `docs/UNIONS.md` §5's cost, pinned rather than left to be discovered: a variant that
    /// declares the tag field gets the key written twice. It still round-trips through Assay
    /// — the pre-scan reads the FIRST occurrence and picks the branch, the field dispatch
    /// takes the LAST and gives the variant its own value back — but the document has a
    /// duplicate key, which not every consumer of it will like.
    @Test("a variant that declares the tag field writes it twice")
    func variantDeclaringTheTag() throws {
        let v = EncCarrying.carrier(EncTagCarrier(type: "custom", x: 1))
        #expect(try v.jsonText() == #"{"type":"carrier","type":"custom","x":1}"#)
        #expect(try EncCarrying.parse(json: v.encodedJSON()) == v)
    }
}

// MARK: - Untagged encoding

@Schema(encodes: true, discriminator: .untagged)
enum EncStringOrNumber: Equatable {
    case text(String)
    case number(Double)
}

@Schema(encodes: true)
struct EncPoint: Equatable { var x: Int; var y: Int }

@Schema(encodes: true)
struct EncLine: Equatable { var from: String; var to: String }

@Schema(encodes: true, discriminator: .untagged)
enum EncFigure: Equatable {
    case point(EncPoint)
    case line(EncLine)
}

@Suite("untagged unions — encoding")
struct UntaggedEncodingTests {

    @Test("the untagged form writes the payload alone")
    func payloadAlone() throws {
        #expect(try EncStringOrNumber.text("hi").jsonText() == #""hi""#)
        #expect(try EncStringOrNumber.number(3.5).jsonText() == "3.5")
        #expect(try EncFigure.point(EncPoint(x: 1, y: 2)).jsonText() == #"{"x":1,"y":2}"#)
    }

    @Test("round trip: untagged")
    func untaggedRoundTrip() throws {
        for v in [EncStringOrNumber.text("hi"), .number(3.5)] {
            #expect(try EncStringOrNumber.parse(json: v.encodedJSON()) == v)
        }
        for v in [EncFigure.point(EncPoint(x: 1, y: 2)),
                  .line(EncLine(from: "a", to: "b"))] {
            #expect(try EncFigure.parse(json: v.encodedJSON()) == v)
        }
    }

    /// Q4 reaches a union member: a `Double` with no JSON spelling reports rather than
    /// writing `nan`, and the case name stands in for the key it does not have.
    @Test("an unrepresentable Double reports against the case name")
    func unrepresentableDouble() {
        let d = EncStringOrNumber.number(.infinity).diagnoseEncodeJSON()
        #expect(!d.isValid)
        // The key goes in the PATH — a union member has no key of its own, so the case name
        // stands in for one, exactly as it does on the decode side.
        #expect(d.issues.first?.path.last == .key("number"))
    }
}
