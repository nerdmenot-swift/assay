// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Foundation
import Assay
import AssayCore
import AssayFoundation
import AssayYAML
import AssayXML
import AssayTOML

//===----------------------------------------------------------------------===//
// `UUID` as a field type (`AssayFoundation/UUIDSupport.swift`).
//
// This file exists because a coverage pass on 2026-09-23 found `UUIDSupport.swift` at
// **zero percent**: eighty lines providing `UUID._assay` for the JSON reader and for
// `RawValue`, reachable from every format, and not one test decoded a `UUID`. The only
// mentions of the type anywhere in the suite were a golden expansion fixture — which
// checks the macro's OUTPUT, never running it — and the `.uuid` rule, which is a different
// mechanism entirely.
//
// Decoding turned out to work. **Encoding did not**: `@Schema(encodes: true)` with a `UUID`
// field failed to compile with "value of type 'UUID' has no member '_assayEncode'", an
// internal member named at the user, which is exactly the class of error
// `CapabilityRefusals.swift` exists to prevent. Foundation's type cannot be given the
// conformance (it would acquire a `parse(json:)` of its own — `TypeShapes.swift` says why),
// so the four emitters special-case it as they already special-case `Date`.
//
// THE ACCEPTANCE RULE IS THE `.uuid` RULE'S, EXACTLY, and that equivalence is the reason
// most of this file is refusals: `@Validate(.uuid) var s: String` and `var u: UUID` must
// agree about every string, or one of them is lying. `FormatValidators.isUUID` settles it —
// canonical 8-4-4-4-12 hex, either case, nothing else.
//===----------------------------------------------------------------------===//

@Schema(keys: .snakeCase, formats: .all, encodes: true)
struct UUIDHolder: Equatable {
    var id: UUID
    var name: String
}

@Schema(encodes: true)
struct UUIDShapes: Equatable {
    var one: UUID
    var maybe: UUID?
    var many: [UUID]
}

@Schema
struct UUIDValidated: Equatable {
    @Validate(.uuid) var text: String
}

@Suite("UUID fields")
struct UUIDFieldTests {

    static let canonical = "3db7582f-b24c-4245-8556-3c25956d108f"
    static let expected = UUID(uuidString: canonical)!

    // MARK: Decoding, on every path

    @Test("JSON decodes the canonical form")
    func json() throws {
        let v = try UUIDHolder.parse(json: Array(#"{"id":"\#(Self.canonical)","name":"a"}"#.utf8))
        #expect(v.id == Self.expected)
    }

    @Test("the RawValue path decodes it too — YAML, TOML and XML")
    func rawPaths() throws {
        let y = try UUIDHolder.parse(yaml: "id: \(Self.canonical)\nname: a\n")
        #expect(y.id == Self.expected)

        let t = try UUIDHolder.parse(toml: "id = \"\(Self.canonical)\"\nname = \"a\"\n")
        #expect(t.id == Self.expected)

        let x = try UUIDHolder.parse(
            xml: Array("<r><id>\(Self.canonical)</id><name>a</name></r>".utf8))
        #expect(x.id == Self.expected)
    }

    @Test("upper case decodes, because the rule accepts it")
    func upperCase() throws {
        let upper = Self.canonical.uppercased()
        let v = try UUIDHolder.parse(json: Array(#"{"id":"\#(upper)","name":"a"}"#.utf8))
        #expect(v.id == Self.expected, "a UUID is case-insensitive; the VALUE is the same")
    }

    @Test("optionals and arrays of UUID")
    func shapes() throws {
        let json = #"{"one":"\#(Self.canonical)","many":["\#(Self.canonical)"]}"#
        let v = try UUIDShapes.parse(json: Array(json.utf8))
        #expect(v.one == Self.expected)
        #expect(v.maybe == nil)
        #expect(v.many == [Self.expected])
    }

    // MARK: What it refuses, and the equivalence that forces each one

    /// Each of these is a form some UUID parser somewhere accepts, and every one of them
    /// must be refused identically by the field type and by the rule — otherwise
    /// `@Validate(.uuid) var s: String` and `var u: UUID` disagree about the same document.
    @Test("the refused spellings are refused by BOTH the field type and the rule", arguments: [
        "{3db7582f-b24c-4245-8556-3c25956d108f}",        // braces
        "urn:uuid:3db7582f-b24c-4245-8556-3c25956d108f", // the URN form
        "3db7582fb24c424585563c25956d108f",              // bare 32 hex, no hyphens
        "3db7582f-b24c-4245-8556-3c25956d108",           // one short
        "3db7582f-b24c-4245-8556-3c25956d108ff",         // one long
        "3db7582f-b24c-4245-8556-3c25956d108g",          // not hex
        "3db7582f_b24c_4245_8556_3c25956d108f",          // wrong separator
        "",
        "not a uuid at all",
    ])
    func refusedEverywhere(_ text: String) {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let d = UUIDHolder.diagnose(json: Array(#"{"id":"\#(escaped)","name":"a"}"#.utf8))
        #expect(d.value == nil, "field type accepted \(text)")
        #expect(d.issues.map(\.code) == [.typeMismatch])

        let r = UUIDValidated.diagnose(json: Array(#"{"text":"\#(escaped)"}"#.utf8))
        #expect(!r.isValid, "the .uuid rule accepted \(text) while the field type refused it")
    }

    @Test("a non-string JSON value is a mismatch, not a crash", arguments: ["7", "true", "null", "[]", "{}"])
    func notAString(_ literal: String) {
        let d = UUIDHolder.diagnose(json: Array(#"{"id":\#(literal),"name":"a"}"#.utf8))
        #expect(d.value == nil)
        #expect(!d.issues.isEmpty)
    }

    @Test("the issue names the field and carries the text it read")
    func issueShape() throws {
        let d = UUIDHolder.diagnose(json: Array(#"{"id":"nope","name":"a"}"#.utf8))
        let issue = try #require(d.issues.first)
        #expect(issue.path == [.key("id")])
        #expect(issue.received == "nope")
        #expect(issue.message.contains("uuid"))
    }

    @Test("a bad UUID on the RawValue path reports the same way")
    func rawMismatch() {
        let d = UUIDHolder.diagnose(yaml: "id: nope\nname: a\n")
        #expect(d.value == nil)
        #expect(d.issues.map(\.code) == [.typeMismatch])
    }

    // MARK: Encoding — the half that did not exist

    @Test("a UUID field encodes as its canonical text, on every format")
    func encodes() throws {
        let v = UUIDHolder(id: Self.expected, name: "a")
        let json = try v.jsonText()
        #expect(json.contains(Self.canonical.uppercased()))

        #expect(try v.yamlText().contains(Self.canonical.uppercased()))
        #expect(try v.tomlText().contains(Self.canonical.uppercased()))
        #expect(try v.xmlText().contains(Self.canonical.uppercased()))
    }

    /// `docs/ENCODING.md`'s law is about the VALUE, and it holds here even though the bytes
    /// change case: `uuidString` is upper-case and the document was lower-case.
    @Test("round-trip is exact on the value, on every format")
    func roundTrip() throws {
        let v = UUIDHolder(id: Self.expected, name: "a")
        #expect(try UUIDHolder.parse(json: v.encodedJSON().toArray()) == v)
        #expect(try UUIDHolder.parse(yaml: v.yamlText()) == v)
        #expect(try UUIDHolder.parse(toml: v.tomlText()) == v)
        #expect(try UUIDHolder.parse(xml: Array(v.xmlText().utf8)) == v)
    }

    @Test("optionals and arrays encode too")
    func encodeShapes() throws {
        let v = UUIDShapes(one: Self.expected, maybe: Self.expected, many: [Self.expected])
        let text = try v.jsonText()
        #expect(try UUIDShapes.parse(json: Array(text.utf8)) == v)

        let empty = UUIDShapes(one: Self.expected, maybe: nil, many: [])
        #expect(try UUIDShapes.parse(json: Array(empty.jsonText().utf8)) == empty)
    }
}
