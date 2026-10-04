// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
@testable import AssayCore

//===----------------------------------------------------------------------===//
// AssayCore's remaining arms: UTF-8 validation by lead-byte class, the rule→keyword table
// of the JSON Schema renderer, scalar mismatches on optional fields, the value model's
// document-level refusals, and the messages nobody had read.
//===----------------------------------------------------------------------===//

@Schema struct OneString: Equatable { var s: String }

// MARK: - UTF-8

/// The validator runs over every document before anything else, on bytes an attacker
/// chose. Its three- and four-byte arms split by lead byte because each lead has a
/// different legal range for the SECOND byte — that is where overlong encodings,
/// surrogates and code points past U+10FFFF are refused. The suite had exercised the
/// two-byte arm and the common three-byte one (E1–EC). `E0`, `ED`, `F1`–`F3` and `F4` had
/// never been validated by a test: not their accepted ranges, and not what they refuse.
@Suite("UTF-8 validation, by lead byte")
struct UTF8LeadByteTests {

    /// A JSON document `{"s":"<bytes>"}` and the offset of the first payload byte.
    static func document(_ payload: [UInt8]) -> (bytes: [UInt8], at: Int) {
        let head = Array(#"{"s":""#.utf8)
        return (head + payload + Array(#""}"#.utf8), head.count)
    }

    @Test(
        "every well-formed sequence is accepted and decodes to its scalar",
        arguments: [
            [0xC2, 0x80], [0xDF, 0xBF],  // U+0080, U+07FF
            [0xE0, 0xA0, 0x80], [0xE0, 0xBF, 0xBF],  // U+0800, U+0FFF — E0's legal range
            [0xE1, 0x80, 0x80], [0xEC, 0xBF, 0xBF],
            [0xED, 0x80, 0x80], [0xED, 0x9F, 0xBF],  // U+D000, U+D7FF — below the surrogates
            [0xEE, 0x80, 0x80], [0xEF, 0xBF, 0xBF],  // U+E000, U+FFFF
            [0xF0, 0x90, 0x80, 0x80], [0xF0, 0xBF, 0xBF, 0xBF],  // U+10000 up
            [0xF1, 0x80, 0x80, 0x80], [0xF3, 0xBF, 0xBF, 0xBF],
            [0xF4, 0x80, 0x80, 0x80], [0xF4, 0x8F, 0xBF, 0xBF]  // …U+10FFFF
        ] as [[UInt8]])
    func accepted(_ payload: [UInt8]) throws {
        let v = try OneString.parse(json: Self.document(payload).bytes)
        #expect(Array(v.s.utf8) == payload)
        #expect(v.s.unicodeScalars.count == 1)
    }

    @Test(
        "every ill-formed sequence is refused at its lead byte",
        arguments: [
            [0x80], [0xBF],  // a continuation with nothing to continue
            [0xC0, 0x80], [0xC1, 0xBF],  // overlong two-byte
            [0xC2, 0x41],  // lead, then not a continuation
            [0xE0, 0x80, 0x80], [0xE0, 0x9F, 0xBF],  // overlong three-byte
            [0xE1, 0x80, 0x41], [0xE1, 0x41, 0x80],
            [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF],  // UTF-16 surrogates
            [0xF0, 0x80, 0x80, 0x80], [0xF0, 0x8F, 0xBF, 0xBF],  // overlong four-byte
            [0xF1, 0x80, 0x80, 0x41], [0xF1, 0x41, 0x80, 0x80],
            [0xF4, 0x90, 0x80, 0x80],  // past U+10FFFF
            [0xF5, 0x80, 0x80, 0x80], [0xFF]  // not a lead byte at all
        ] as [[UInt8]])
    func refused(_ payload: [UInt8]) {
        let (bytes, at) = Self.document(payload)
        let d = OneString.diagnose(json: bytes)
        #expect(d.issues.map(\.code) == [.invalidUTF8], "\(payload)")
        #expect(d.issues.first?.params["offset"] == .int(at), "\(payload)")
        #expect(d.issues.first?.message == "input is not valid UTF-8 (byte \(at))")
    }

    @Test(
        "a sequence cut off by the end of the input is refused, not read past",
        arguments: [
            [0xC2], [0xE0, 0xA0], [0xE1, 0x80], [0xED, 0x80], [0xF0, 0x90, 0x80], [0xF1],
            [0xF4, 0x80]
        ]
            as [[UInt8]])
    func truncated(_ payload: [UInt8]) {
        let head = Array(#"{"s":""#.utf8)
        let d = OneString.diagnose(json: head + payload)
        #expect(d.issues.first?.code == .invalidUTF8, "\(payload)")
        #expect(d.issues.first?.params["offset"] == .int(head.count), "\(payload)")
    }
}

// MARK: - JSON Schema keywords

@Suite("JSON Schema: one rule, one keyword")
struct JSONSchemaKeywordTests {

    private func render(_ type: TypeDescriptor, _ rules: Rule...) -> String {
        // One line, so a row reads as the JSON it stands for.
        JSONSchemaRender.schema(for: type, rules: rules).text()
            .split(whereSeparator: \.isNewline)
            .map { $0.drop(while: { $0 == " " }) }.joined(separator: " ")
    }

    @Test("a bound means length on a string, a count on an array, a magnitude on a number")
    func polymorphicBounds() {
        #expect(
            render(.string, .min(2), .max(5))
                == #"{ "type": "string", "minLength": 2, "maxLength": 5 }"#)
        #expect(
            render(.number, .min(1.5), .max(9))
                == #"{ "type": "number", "minimum": 1.5, "maximum": 9 }"#)
        #expect(
            render(.array(.boolean), .min(1), .max(3))
                == #"{ "type": "array", "items": { "type": "boolean" }, "minItems": 1, "maxItems": 3 }"#
        )
        #expect(
            render(.integer, .range(1...9)) == #"{ "type": "integer", "minimum": 1, "maximum": 9 }"#
        )
        #expect(
            render(.string, .range(1...9))
                == #"{ "type": "string", "minLength": 1, "maxLength": 9 }"#)
        #expect(
            render(.array(.integer), .range(1...9))
                == #"{ "type": "array", "items": { "type": "integer" }, "minItems": 1, "maxItems": 9 }"#
        )
    }

    @Test("length, emptiness and count")
    func counts() {
        #expect(
            render(.string, .length(3)) == #"{ "type": "string", "minLength": 3, "maxLength": 3 }"#)
        #expect(render(.string, .notEmpty) == #"{ "type": "string", "minLength": 1 }"#)
        #expect(
            render(.array(.string), .notEmpty, .count(2...4), .unique)
                == #"{ "type": "array", "items": { "type": "string" }, "minItems": 1, "minItems": 2, "maxItems": 4, "uniqueItems": true }"#
        )
    }

    @Test("string rules: formats, patterns with their literals escaped, and an enum")
    func strings() {
        #expect(render(.string, .url) == #"{ "type": "string", "format": "uri" }"#)
        #expect(render(.string, .hostname) == #"{ "type": "string", "format": "hostname" }"#)
        #expect(render(.string, .regex("^a+$")) == #"{ "type": "string", "pattern": "^a+$" }"#)
        #expect(
            render(.string, .ascii) == #"{ "type": "string", "pattern": "^[\\u0000-\\u007F]*$" }"#)
        // A literal prefix is ESCAPED: `a.b` as a pattern would also match `axb`, which
        // describes less than the rule accepts — the direction the renderer never errs in.
        #expect(render(.string, .prefix("a.b")) == #"{ "type": "string", "pattern": "^a\\.b" }"#)
        #expect(render(.string, .suffix("(x)")) == #"{ "type": "string", "pattern": "\\(x\\)$" }"#)
        #expect(render(.string, .contains("a+b")) == #"{ "type": "string", "pattern": "a\\+b" }"#)
        #expect(
            render(.string, .oneOf(["x", "y"])) == #"{ "type": "string", "enum": [ "x", "y" ] }"#)
    }

    @Test("number rules")
    func numbers() {
        #expect(render(.integer, .positive) == #"{ "type": "integer", "exclusiveMinimum": 0 }"#)
        #expect(render(.integer, .negative) == #"{ "type": "integer", "exclusiveMaximum": 0 }"#)
        #expect(render(.integer, .nonNegative) == #"{ "type": "integer", "minimum": 0 }"#)
        #expect(render(.number, .multipleOf(0.25)) == #"{ "type": "number", "multipleOf": 0.25 }"#)
        // `.finite` constrains nothing JSON can spell, so it adds nothing.
        #expect(render(.number, .finite) == #"{ "type": "number" }"#)
    }

    @Test("rules with no exact keyword become prose, joined, rather than an approximate pattern")
    func prose() {
        #expect(
            render(.string, .isTrimmed, .isLowercase)
                == #"{ "type": "string", "description": "must have no leading or trailing whitespace; must be lowercase" }"#
        )
        #expect(
            render(.date(numeric: false), .before("2030-01-01"))
                == #"{ "type": "string", "format": "date-time", "description": "must be before 2030-01-01" }"#
        )
        #expect(
            render(
                .date(numeric: false), .after("2020-01-01"), .between("2020-01-01", "2030-01-01")
            )
            .hasSuffix(
                #""description": "must be after 2020-01-01; must be between 2020-01-01 and 2030-01-01" }"#
            )
        )
    }

    @Test("composition, a message-only rule, an open value and a boolean")
    func rest() {
        #expect(
            render(.string, .all(.min(1), .email), "just a message")
                == #"{ "type": "string", "minLength": 1, "format": "email" }"#)
        #expect(render(.opaque("RawValue")) == "{}")
        #expect(render(.boolean) == #"{ "type": "boolean" }"#)
        #expect(
            render(.optional(.number), .min(0))
                == #"{ "type": [ "number", "null" ], "minimum": 0 }"#)
    }

    @Test("text(): a non-integral number, and control characters escaped as \\u00XX")
    func text() {
        #expect(JSONSchemaValue.number(0.5).text() == "0.5")
        #expect(JSONSchemaValue.number(3).text() == "3")
        #expect(
            JSONSchemaValue.string("a\u{01}b\u{1F}\r\t\n\"\\").text()
                == #""a\u0001b\u001f\r\t\n\"\\""#)
        #expect(JSONSchemaValue.array([]).text() == "[]")
        #expect(JSONSchemaValue.object([]).text() == "{}")
    }
}

// MARK: - Scalars on optional fields, and coerced booleans

@Schema
struct OptionalScalars: Equatable {
    var i: Int?
    var i64: Int64?
    var i32: Int32?
    var u: UInt?
    var d: Double?
    var f: Float?
    var b: Bool?
    var xs: [Double] = []
}

@Schema struct CoercedFlag: Equatable { @Coerce var on: Bool }

@Suite("Optional scalars and coerced booleans")
struct OptionalScalarTests {

    @Test(
        "a wrong-typed value on an optional field is a mismatch naming what was wanted",
        arguments: [
            ("i", "integer"), ("i64", "integer"), ("i32", "integer"), ("u", "unsigned integer"),
            ("d", "number"), ("f", "number"), ("b", "boolean")
        ])
    func mismatch(field: String, expected: String) {
        let d = OptionalScalars.diagnose(json: "{\"\(field)\":\"x\"}")
        #expect(d.issues.map(\.code) == [.typeMismatch], "\(field)")
        #expect(d.issues.first?.path.pathDescription == field)
        #expect(d.issues.first?.params["expected"] == .string(expected), "\(field)")
    }

    @Test("an element of a [Double] that is not a number names the element")
    func elementMismatch() {
        let d = OptionalScalars.diagnose(json: #"{"xs":[1.5,"x",2]}"#)
        #expect(d.issues.map(\.code) == [.typeMismatch])
        #expect(d.issues.first?.path.pathDescription == "xs[1]")
    }

    @Test("@Coerce on a Bool: 1 and 0, the strings, and nothing else")
    func coercedBool() throws {
        #expect(try CoercedFlag.parse(json: #"{"on":1}"#).on)
        #expect(try CoercedFlag.parse(json: #"{"on":0}"#).on == false)
        #expect(try CoercedFlag.parse(json: #"{"on":"true"}"#).on)
        #expect(try CoercedFlag.parse(json: #"{"on":"no"}"#).on == false)
        for bad in ["2", "\"maybe\"", "[1]"] {
            let d = CoercedFlag.diagnose(json: "{\"on\":\(bad)}")
            #expect(d.issues.first?.params["expected"] == .string("boolean"), "\(bad)")
        }
    }
}

// MARK: - JSON.Value's document-level refusals

@Suite("JSON.Value: what the document door refuses")
struct JSONValueRefusalTests {

    private func codes(_ text: String, limits: Limits = .default) -> [IssueCode] {
        var sink = IssueSink(limits: limits)
        _ = JSON.Value.decode(Array(text.utf8), into: &sink, limits: limits)
        return sink.issues.map(\.code)
    }

    @Test("an empty document, one over maxBytes, and a number no Double holds")
    func refusals() {
        #expect(codes("") == [.malformedDocument])
        var small = Limits.default
        small.maxBytes = 3
        #expect(codes("[1,2,3]", limits: small) == [.tooManyBytes])
        #expect(codes("[1e999]") == [.numberOverflow])
        #expect(codes(#"{"a":1 "b":2}"#) == [.malformedDocument])
    }
}

// MARK: - Messages

/// `Issue.message` is derived on demand from a code and its params, and several of these
/// had never been derived by a test — including the common, params-present form of four of
/// them. A message is the only part of an issue most people read.
@Suite("Messages nobody had read")
struct MessageDerivationTests {

    @Test(
        "with its params, each code says something specific",
        arguments: [
            (AssayCore.Issue(code: .numberOverflow), "number is out of range"),
            (
                AssayCore.Issue(code: .invalidUTF8, params: ["offset": .int(7)]),
                "input is not valid UTF-8 (byte 7)"
            ),
            (AssayCore.Issue(code: .duplicateKey, received: "id"), #"duplicate key "id""#),
            (
                AssayCore.Issue(code: .depthExceeded, params: ["maxDepth": .int(64)]),
                "nesting exceeds the maximum depth of 64"
            ),
            (
                AssayCore.Issue(code: .tooManyBytes, params: ["maxBytes": .int(10)]),
                "input exceeds the maximum size of 10 bytes"
            ),
            (
                AssayCore.Issue(
                    code: .wrongCount, params: ["minimum": .int(1), "maximum": .int(3)]),
                "must contain between 1 and 3 items"
            ),
            (
                AssayCore.Issue(code: .patternMismatch, params: ["pattern": .string("^a$")]),
                "must match the pattern ^a$"
            ),
            (
                AssayCore.Issue(code: .invalidRegexPattern, params: ["pattern": .string("(")]),
                "the rule's pattern ( is not a valid regular expression"
            ),
            (
                AssayCore.Issue(code: .notMultiple, params: ["multipleOf": .int(5)]),
                "must be a multiple of 5"
            ),
            (
                AssayCore.Issue(
                    code: .custom("union_budget_exhausted"), params: ["maxUnionAttempts": .int(8)]),
                "union backtracking exceeded 8 attempts (Limits.maxUnionAttempts)"
            ),
            (
                AssayCore.Issue(code: .custom("plist_too_deep"), params: ["maxDepth": .int(64)]),
                "property list nests deeper than 64 levels (Limits.maxDepth)"
            ),
            (
                AssayCore.Issue(
                    code: .custom("toml_inline_table_closed"), params: ["key": .string("a")]),
                "inline table 'a' cannot be extended after it is defined"
            ),
            (
                AssayCore.Issue(code: .custom("toml_not_a_table"), params: ["key": .string("a")]),
                "'a' is not a table and cannot be extended"
            )
        ])
    func specific(issue: AssayCore.Issue, message: String) {
        #expect(issue.message == message)
    }

    @Test(
        "without them, it still says something true rather than printing a placeholder",
        arguments: [
            (AssayCore.Issue(code: .invalidUTF8), "input is not valid UTF-8"),
            (AssayCore.Issue(code: .duplicateKey), "duplicate key"),
            (AssayCore.Issue(code: .depthExceeded), "nesting exceeds the maximum depth"),
            (AssayCore.Issue(code: .tooManyBytes), "input exceeds the maximum size"),
            // `Limits.mapped` sets maxBytes to Int.max; "of 9223372036854775807 bytes" is noise.
            (
                AssayCore.Issue(code: .tooManyBytes, params: ["maxBytes": .int(.max)]),
                "input exceeds the maximum size"
            )
        ])
    func fallback(issue: AssayCore.Issue, message: String) {
        #expect(issue.message == message)
    }

    @Test("a union's summary names the closest variant; a date fallback names both formats")
    func composed() {
        let union = AssayCore.Issue(
            code: .custom("union_no_variant_matched"),
            params: ["type": .string("Event"), "variants": .string("a, b"), "closest": .string("a")]
        )
        #expect(
            union.message
                == "did not match any variant of Event (a, b); closest was a, whose issues follow")

        let d = TreeDates.diagnose(
            json: #"{"at":1,"chained":1700000000,"iso":"2023-11-14T22:13:20Z"}"#)
        #expect(
            d.warnings.first?.message
                == "matched the fallback format unix timestamp (seconds), not the primary ISO-8601 date"
        )
    }
}
