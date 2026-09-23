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
        let a = try UnionEvent.parse(
            json: #"""
                {"x":1,"ignored":{"deep":[1,2,{"deeper":true}]},"type":"click","y":2}
                """#)
        #expect(a == .click(UnionClick(x: 1, y: 2)))
    }

    @Test("a case's tag spelling follows keys:, and @Key overrides it")
    func tagSpelling() throws {
        #expect(
            try UnionEvent.parse(json: #"{"type":"page_view","url":"/"}"#)
                == .pageView(UnionPageView(url: "/", referrer: nil)))
        #expect(
            try UnionShape.parse(json: #"{"kind":"circular","x":1,"y":2}"#)
                == .circle(UnionClick(x: 1, y: 2)))
        #expect(
            try UnionShape.parse(json: #"{"kind":"square","x":1,"y":2}"#)
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
        let e = try UnionEnvelope.parse(
            json: #"""
                {"id":"e1","payload":{"type":"click","x":3,"y":4}}
                """#)
        #expect(e == UnionEnvelope(id: "e1", payload: .click(UnionClick(x: 3, y: 4))))
    }

    @Test("a union works in an array")
    func inArray() throws {
        let b = try UnionBatch.parse(
            json: #"""
                {"events":[{"type":"click","x":1,"y":2},{"type":"page_view","url":"/a"}]}
                """#)
        #expect(b.events.count == 2)
        #expect(b.events[0] == .click(UnionClick(x: 1, y: 2)))
        #expect(b.events[1] == .pageView(UnionPageView(url: "/a", referrer: nil)))
    }
}
