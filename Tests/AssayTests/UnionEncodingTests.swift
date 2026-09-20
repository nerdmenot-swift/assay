// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.


//===----------------------------------------------------------------------===//
// Union encoding, both forms. `docs/UNIONS.md` §4 was written as "the settled answer for
// when it is built"; these are its four claims turned into assertions.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayCore

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
            #expect(try EncEvent.parse(json: value.encodedJSON().toArray()) == value)
        }
    }

    @Test("a union as a field, and as an array element")
    func nestedInStructs() throws {
        let e = EncEnvelope(id: "e1", payload: .click(EncClick(x: 1, y: 2)))
        #expect(try e.jsonText() == #"{"id":"e1","payload":{"type":"click","x":1,"y":2}}"#)
        #expect(try EncEnvelope.parse(json: e.encodedJSON().toArray()) == e)

        let b = EncBatch(events: [.click(EncClick(x: 1, y: 2)),
                                  .pageView(EncPageView(url: "/z", referrer: nil))])
        #expect(try EncBatch.parse(json: b.encodedJSON().toArray()) == b)
    }

    @Test("a union inside a union writes one object with both tags")
    func unionInsideUnion() throws {
        let v = EncOuter.inner(.click(EncClick(x: 7, y: 8)))
        #expect(try v.jsonText() == #"{"type":"inner","sub":"click","x":7,"y":8}"#)
        #expect(try EncOuter.parse(json: v.encodedJSON().toArray()) == v)
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
        #expect(try EncCarrying.parse(json: v.encodedJSON().toArray()) == v)
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
            #expect(try EncStringOrNumber.parse(json: v.encodedJSON().toArray()) == v)
        }
        for v in [EncFigure.point(EncPoint(x: 1, y: 2)),
                  .line(EncLine(from: "a", to: "b"))] {
            #expect(try EncFigure.parse(json: v.encodedJSON().toArray()) == v)
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
