// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore
import AssayTOML
import AssayYAML

//===----------------------------------------------------------------------===//
// A nil optional under `@Key(path:)`, encoded.
//
// `docs/ENCODING.md` states what a nil member does at the top of a type: JSON and YAML
// write an explicit null, TOML omits the key because it has no null. Nothing said, or
// tested, what happens when that member sits two objects down a key path — where the
// intermediate objects exist ONLY because of the path, and a nil leaf leaves one of them
// with nothing in it.
//
// The answer is the same rule applied where the leaf is, and the intermediate is still
// written. That is the form that round-trips: the decoder reads a missing intermediate as
// absence and an empty one as absence too, so neither spelling loses the value. What would
// NOT be fine is TOML reporting `toml_no_null` for it — a nil optional is the one null the
// TOML encoder is obliged to swallow, and a path must not turn it into a failure.
//===----------------------------------------------------------------------===//

@Schema(formats: [.json, .yaml, .toml], encodes: true)
private struct PathedOptional: Equatable {
    var a: Int
    @Key(path: "p.q") var q: Int
    @Key(path: "p.r.s") var s: String?
    @Key(path: "z.only") var only: String?
}

@Suite("Encoding a nil optional under a key path")
struct PathEncodingTests {

    private static let empty = PathedOptional(a: 1, q: 2, s: nil, only: nil)
    private static let full = PathedOptional(a: 1, q: 2, s: "x", only: "y")

    @Test("JSON writes the null where the leaf is, inside the objects the path names")
    func json() throws {
        let text = try Self.empty.encodedJSON().text()
        #expect(text == #"{"a":1,"p":{"q":2,"r":{"s":null}},"z":{"only":null}}"#)
        #expect(try PathedOptional.parse(json: text) == Self.empty)
    }

    @Test("YAML does the same through the RawValue seam")
    func yaml() throws {
        let text = try Self.empty.encodedYAML().text()
        #expect(text.contains("    s: null"))
        #expect(try PathedOptional.parse(yaml: text) == Self.empty)
    }

    @Test("TOML omits the leaf, keeps the table, and reports nothing")
    func toml() throws {
        let d = Self.empty.diagnoseEncodeTOML()
        #expect(d.issues.isEmpty, "a nil optional is not toml_no_null: \(d.issues)")
        let text = String(decoding: d.bytes, as: UTF8.self)
        #expect(text.contains("[p]\nq = 2"))
        #expect(!text.contains("only"))
        #expect(try PathedOptional.parse(toml: text) == Self.empty)
    }

    @Test("with values present, all three round-trip")
    func populated() throws {
        let v = Self.full
        #expect(try PathedOptional.parse(json: try v.encodedJSON().text()) == v)
        #expect(try PathedOptional.parse(yaml: try v.encodedYAML().text()) == v)
        #expect(try PathedOptional.parse(toml: try v.tomlText()) == v)
    }
}
