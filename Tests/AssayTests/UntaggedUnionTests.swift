// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.


//===----------------------------------------------------------------------===//
// Untagged unions. `docs/UNIONS.md` §§2.2 and 3: everything a tagged union does not have
// to answer — which branch to blame when they all fail, and what stops nested unions
// from going exponential.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayCore

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

        let summary = d.issues.first { $0.code == .unionNoVariantMatched }
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
        let summary = d.issues.first { $0.code == .unionNoVariantMatched }
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
        #expect(d.issues.contains { $0.code == .unionBudgetExhausted },
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
        #expect(d.issues.contains { $0.code == .unionBudgetExhausted },
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
