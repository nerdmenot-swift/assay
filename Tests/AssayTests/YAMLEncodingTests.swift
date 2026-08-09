// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// YAML encoding, and the round-trip law for it. docs/ENCODING.md.
//
// The law is the same one JSON gets, but the way it can BREAK is entirely different, and
// that is what most of this file tests. JSON has one string syntax; YAML has plain style,
// and a plain scalar is typed by what it looks like. So `RawValue.string("123")` written
// bare comes back an integer, `"true"` comes back a boolean, `"~"` comes back null — the
// Norway problem arriving from the encode side.
//
// Assay's decoder sidesteps that by never resolving a plain scalar until asked. The
// encoder has to pay for the same guarantee in the other direction, by quoting anything
// that could read as another type. These tests are what hold it to that.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayYAML

@Schema(keys: .snakeCase, formats: .all, encodes: true)
struct YEnc: Equatable {
    var name: String
    var count: Int
    var ratio: Double
    var active: Bool
    var note: String?
    var tags: [String] = []
    var counts: [String: Int] = [:]
    var nested: YEncInner
    var items: [YEncInner] = []
}

@Schema(keys: .snakeCase, formats: .all, encodes: true)
struct YEncInner: Equatable {
    var id: String
    var amount: Double
}

@Schema(formats: .all, encodes: true)
struct YScalar: Equatable {
    var s: String
}

@Suite("YAML encoding")
struct YAMLEncodingTests {

    @Test("round-trip: parse -> encode -> parse is identity")
    func roundTrip() throws {
        let yaml = """
        name: hello
        count: 42
        ratio: 0.25
        active: true
        note: something
        tags:
          - a
          - b
        counts:
          x: 1
          y: 2
        nested:
          id: n
          amount: 1.5
        items:
          - id: i1
            amount: 2.5
          - id: i2
            amount: -3
        """
        let original = try YEnc.parse(yaml: yaml)
        let encoded = try original.encodedYAML()
        let again = try YEnc.parse(yaml: encoded)
        #expect(again == original, "round-trip must be identity; got:\n\(String(decoding: encoded, as: UTF8.self))")
    }

    /// The heart of it. Every one of these strings, written bare, reads back as a
    /// different type — so every one must come out quoted.
    @Test("strings that look like other types survive", arguments: [
        "123", "-7", "0", "3.14", "1e3", "0x1F", "0o17",
        "true", "True", "TRUE", "false", "False",
        "null", "Null", "NULL", "~", "",
        ".inf", "-.inf", ".nan",
        "yes", "no", "on", "off", "NO", "Y",
        "2026-08-09", "1.2.3", "01234",
    ])
    func scalarsSurvive(_ s: String) throws {
        let v = YScalar(s: s)
        let text = try v.yamlText()
        let again = try YScalar.parse(yaml: text)
        #expect(again.s == s, "\"\(s)\" encoded as `\(text.trimmingCharacters(in: .whitespacesAndNewlines))` and came back as \"\(again.s)\"")
    }

    @Test("structural and whitespace hazards survive", arguments: [
        "a: b", "- item", "# comment", "key:", "[1,2]", "{a: 1}", "*alias", "&anchor",
        "|literal", ">folded", "%directive", "@at", "`tick", "!tag", "?question",
        " leading", "trailing ", "  ", "line\nbreak", "tab\there", "quote\"inside",
        "back\\slash", "'single'", "---", "...", "a #comment", "café", "😀",
    ])
    func hazardsSurvive(_ s: String) throws {
        let v = YScalar(s: s)
        let text = try v.yamlText()
        let again = try YScalar.parse(yaml: text)
        #expect(again.s == s, "\"\(s)\" came back as \"\(again.s)\" from `\(text)`")
    }

    @Test("keys are quoted when they need to be")
    func keyQuoting() throws {
        let v = YEnc(name: "n", count: 0, ratio: 0, active: false, note: nil,
                     tags: [], counts: ["true": 1, "123": 2, "a: b": 3, "ok": 4],
                     nested: YEncInner(id: "i", amount: 0), items: [])
        let again = try YEnc.parse(yaml: v.encodedYAML())
        #expect(again.counts == v.counts, "dangerous keys must survive")
    }

    @Test("empty collections use flow style, since block has no spelling for them")
    func emptyCollections() throws {
        let v = YEnc(name: "n", count: 0, ratio: 0, active: false, note: nil,
                     tags: [], counts: [:], nested: YEncInner(id: "i", amount: 0), items: [])
        let text = try v.yamlText()
        #expect(text.contains("tags: []"))
        #expect(text.contains("counts: {}"))
        #expect(try YEnc.parse(yaml: text) == v)
    }

    @Test("YAML expresses what JSON cannot — NaN and infinity are values, not issues")
    func nonFinite() throws {
        // The one place the YAML encoder is strictly more capable than the JSON one.
        for d in [Double.infinity, -.infinity] {
            let v = YEncInner(id: "x", amount: d)
            let d2 = v.diagnoseEncodeYAML()
            #expect(d2.isValid, "YAML can spell \(d); it must not be reported")
            #expect(try YEncInner.parse(yaml: v.encodedYAML()).amount == d)
        }
        let nan = YEncInner(id: "x", amount: .nan)
        #expect(nan.diagnoseEncodeYAML().isValid)
        #expect(try YEncInner.parse(yaml: nan.encodedYAML()).amount.isNaN)
    }

    @Test("encoding is stable — twice gives identical bytes")
    func stable() throws {
        let v = YEnc(name: "n", count: 1, ratio: 2, active: true, note: "x",
                     tags: ["b", "a"], counts: ["z": 1, "a": 2],
                     nested: YEncInner(id: "i", amount: 3), items: [])
        #expect(try v.encodedYAML() == v.encodedYAML())
    }

    @Test("optionals write null and round-trip to nil")
    func optionals() throws {
        let v = YEnc(name: "n", count: 0, ratio: 0, active: false, note: nil,
                     tags: [], counts: [:], nested: YEncInner(id: "i", amount: 0), items: [])
        #expect(try v.yamlText().contains("note: null"))
        #expect(try YEnc.parse(yaml: v.encodedYAML()) == v)
    }

    @Test("the output is block style — the reason to choose YAML at all")
    func blockStyle() throws {
        let v = YEnc(name: "n", count: 1, ratio: 0, active: true, note: nil,
                     tags: ["a", "b"], counts: ["k": 1],
                     nested: YEncInner(id: "i", amount: 0), items: [])
        let text = try v.yamlText()
        #expect(text.contains("tags:\n  - a\n  - b"), "got:\n\(text)")
        #expect(text.contains("nested:\n  id: i"), "got:\n\(text)")
    }
}
