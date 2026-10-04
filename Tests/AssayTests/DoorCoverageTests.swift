// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Foundation
import Assay
import AssayCore
import AssayFoundation
import AssayXML
import AssayYAML

//===----------------------------------------------------------------------===//
// What was left after the first pass over the writers, rules and runtime doors: the arms
// a coverage listing shows one at a time. Grouped by what they are rather than by file.
//===----------------------------------------------------------------------===//

// MARK: - Optional narrow integers

@Schema
struct OptionalWidths: Equatable {
    var i8: Int8?
    var i16: Int16?
    var u8: UInt8?
    var u16: UInt16?
    var u32: UInt32?
    var u64: UInt64?
}

@Schema
struct CoercedWidths: Equatable {
    @Coerce var i8: Int8
    @Coerce var i16: Int16
    @Coerce var u8: UInt8
    @Coerce var u16: UInt16
    @Coerce var u32: UInt32
    @Coerce var u64: UInt64
}

/// `DecodeWidths.swift` was written off as "permutations no caller instantiates". It is
/// not: `var b: UInt8?` instantiates the `OrNull` form and `@Coerce var b: UInt8` the
/// coercing one. Nothing in the suite declared either.
@Suite("Narrow integers: optional and coerced")
struct NarrowWidthFormTests {

    @Test("an optional width takes null, absence and a value")
    func optional() throws {
        let all = try OptionalWidths.parse(
            json: #"{"i8":-128,"i16":-32768,"u8":255,"u16":65535,"u32":4294967295,"u64":7}"#)
        #expect(all == OptionalWidths(i8: .min, i16: .min, u8: .max, u16: .max, u32: .max, u64: 7))
        let nulls = try OptionalWidths.parse(
            json: #"{"i8":null,"i16":null,"u8":null,"u16":null,"u32":null,"u64":null}"#)
        #expect(nulls == OptionalWidths())
        #expect(try OptionalWidths.parse(json: "{}") == OptionalWidths())
    }

    @Test(
        "an optional width still refuses what does not fit",
        arguments: [
            ("i8", "128"), ("i16", "32768"), ("u8", "256"), ("u16", "65536"),
            ("u32", "4294967296"), ("u64", "-1"), ("u8", "\"x\"")
        ])
    func optionalRefuses(field: String, value: String) {
        let d = OptionalWidths.diagnose(json: "{\"\(field)\":\(value)}")
        #expect(d.issues.count == 1, "\(field)=\(value)")
        #expect(d.issues.first?.path.pathDescription == field)
    }

    @Test("a coerced width reads a string, and reports overflow as overflow")
    func coerced() throws {
        let v = try CoercedWidths.parse(
            json: #"{"i8":"-128","i16":"7","u8":"255","u16":7,"u32":"7","u64":"7"}"#)
        #expect(v == CoercedWidths(i8: .min, i16: 7, u8: .max, u16: 7, u32: 7, u64: 7))

        let doc = #"""
            {"i8":"128","i16":"32768","u8":"256","u16":"65536","u32":"4294967296","u64":"-1"}
            """#
        let d = CoercedWidths.diagnose(json: doc)
        #expect(d.issues.map(\.path.pathDescription) == ["i8", "i16", "u8", "u16", "u32", "u64"])
    }
}

// MARK: - The writers, driven by hand

/// `JSONWriter` and `XMLWriter` are public so a hand-written encoder can use them. The
/// generated bodies call a subset; these are the members only a hand-written one reaches.
@Suite("Writers driven by hand")
struct HandDrivenWriterTests {

    @Test("JSONWriter: a literal key is escaped, and a pre-encoded one is not touched")
    func jsonKeys() {
        var w = JSONWriter()
        w.beginObject()
        w.key("a\tb" as StaticString)
        w.write(Int32(-7))
        w._key(encoded: #""c":"#)
        w.write(UInt(7))
        w.endObject()
        #expect(w.finish().text() == #"{"a\tb":-7,"c":7}"#)
    }

    @Test("JSONWriter, pretty: the value follows its key on the same line")
    func jsonPretty() {
        var w = JSONWriter(pretty: true)
        w.beginObject()
        w.key("a" as StaticString)
        w.write(1)
        w._key(encoded: #""b":"#)
        w.write(true)
        w.endObject()
        #expect(w.finish().text() == "{\n  \"a\": 1,\n  \"b\": true\n}")
    }

    @Test("XMLWriter: typed attributes")
    func xmlAttributes() {
        var w = XMLWriter(declaration: false)
        w.beginElement("e")
        w.attribute("i", 1)
        w.attribute("l", Int64(-2))
        w.attribute("s", Int32(3))
        w.attribute("u", UInt(4))
        w.attribute("b", true)
        w.endElement("e")
        let text = w.finish().text()
        #expect(text.contains(#"i="1""#) && text.contains(#"l="-2""#) && text.contains(#"s="3""#))
        #expect(text.contains(#"u="4""#) && text.contains(#"b="true""#))
    }
}

// MARK: - JSON.Value as a value

@Suite("JSON.Value literals and accessors")
struct JSONValueLiteralTests {

    @Test("literals build the case they look like")
    func literals() {
        let n: JSON.Value = nil
        let b: JSON.Value = false
        let i: JSON.Value = 3
        let d: JSON.Value = 0.5
        let s: JSON.Value = "x"
        let a: JSON.Value = [1, "x", nil]
        #expect(n.isNull && b == .bool(false) && i == .int(3) && d == .double(0.5))
        #expect(s == .string("x") && a == .array([.int(1), .string("x"), .null]))
    }

    @Test("each accessor is nil for every other case")
    func accessors() {
        let s: JSON.Value = "x"
        #expect(s.bool == nil && s.int == nil && s.double == nil)
        #expect(s.array == nil && s.object == nil)
        #expect(JSON.Value.int(1).string == nil)
        // The one conversion: an integer reads as a double. Not the reverse.
        #expect(JSON.Value.int(2).double == 2.0)
        #expect(JSON.Value.double(2.0).int == nil)
    }
}

// MARK: - Encoding that fails

@Schema(unknownKeys: .collect, formats: .all, encodes: true)
struct Collides: Equatable {
    var id: String
    @Extras var rest: [String: RawValue]
}

@Suite("An encode that reports")
struct EncodeFailureTests {

    /// An extras key that is also a declared key: written back it would be a duplicate, so
    /// every encoder reports it instead.
    static let bad = Collides(id: "a", rest: ["id": .string("b"), "other": .int(1)])
    static let good = Collides(id: "a", rest: ["other": .int(1)])

    @Test("every throwing encoder throws, carrying the collision")
    func throwing() {
        #expect(throws: AssayError.self) { _ = try Self.bad.encodedJSON() }
        #expect(throws: AssayError.self) { _ = try Self.bad.encodedYAML() }
        #expect(throws: AssayError.self) { _ = try Self.bad.encodedXML() }
        do {
            _ = try Self.bad.yamlText()
            Issue.record("expected a throw")
        } catch let e as AssayError {
            #expect(e.issues.map(\.code) == [.extrasKeyCollision])
            #expect(e.issues.first?.path.pathDescription == "id")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("EncodeDiagnosis: text, get and description, valid and not")
    func diagnosis() throws {
        let ok = Self.good.diagnoseEncodeJSON()
        #expect(ok.isValid)
        #expect(ok.text == #"{"id":"a","other":1}"#)
        #expect(try ok.get() == Array(ok.text.utf8))
        #expect(ok.description == "valid (\(ok.bytes.count) bytes)")

        let bad = Self.bad.diagnoseEncodeJSON()
        #expect(!bad.isValid)
        #expect(throws: AssayError.self) { try bad.get() }
        #expect(bad.description == bad.render(.plain))
        #expect(bad.description.contains("id"))

        #expect(Self.bad.diagnoseEncodeXML().issues.map(\.code) == [.extrasKeyCollision])
        #expect(Self.bad.diagnoseEncodeYAML().issues.map(\.code) == [.extrasKeyCollision])
    }

    @Test("the clean value round-trips through all three, extras included")
    func roundTrip() throws {
        #expect(try Collides.parse(json: try Self.good.jsonText()) == Self.good)
        #expect(try Collides.parse(yaml: try Self.good.yamlText()) == Self.good)
    }
}

// MARK: - YAML streams

@Suite("YAML: streams through the schema doors")
struct YAMLStreamDoorTests {

    @Test("parseAll reports every bad document, indexed, and throws")
    func parseAllThrows() {
        do {
            _ = try TreeStrict.parseAll(yaml: "i: 1\ni64: 1\nu: 1\n---\ni: x\ni64: 1\nu: 1\n")
            Issue.record("expected a throw")
        } catch let e as AssayError {
            #expect(e.issues.first?.path.pathDescription == "[1].i")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("a body with no document, and one with two")
    func bodyStreams() {
        let empty = TreeOnlyBody.diagnose(
            body: Array("# only a comment\n".utf8), contentType: "application/yaml",
            accepting: [.yaml])
        #expect(empty.issues.map(\.code) == [.yamlEmptyStream])

        // A request body is one document. Two is reported rather than the second being
        // silently dropped — but the first still decodes, so the report is complete.
        let two = TreeOnlyBody.diagnose(
            body: Array("name: a\ncount: 1\n---\nname: b\ncount: 2\n".utf8),
            contentType: "application/yaml", accepting: [.yaml])
        #expect(two.issues.map(\.code) == [.yamlMultipleDocuments])
        #expect(two.issues.first?.params["count"] == .int(2))
    }

    @Test("an unparseable document through the schema door is an issue with no value")
    func malformed() {
        let d = TreeStrict.diagnose(yaml: "i: [1, 2\n", sourceName: "x.yaml")
        #expect(d.value == nil && !d.isValid)
        #expect(d.sourceName == "x.yaml")
    }
}

// MARK: - Contextual JSON and XML doors

@Schema(context: TenantContext.self, formats: [.json, .xml])
struct ContextualDoor: Equatable {
    var role: String
}

@Suite("Contextual doors: the document-level refusals")
struct ContextualDocumentTests {

    static let plan = TenantContext(availableRoles: ["admin"], maximumSeats: 1)

    @Test("invalid UTF-8, trailing content and maxBytes are refused as on the plain door")
    func jsonRefusals() {
        let badUTF8: [UInt8] = Array(#"{"role":""#.utf8) + [0xFF] + Array(#""}"#.utf8)
        let utf8 = ContextualDoor.diagnose(json: badUTF8, context: Self.plan)
        #expect(utf8.issues.map(\.code) == [.invalidUTF8])
        #expect(utf8.issues.first?.location?.lo == 9)

        let trailing = ContextualDoor.diagnose(json: #"{"role":"admin"} x"#, context: Self.plan)
        #expect(trailing.issues.map(\.code) == [.trailingContent])

        var limits = Limits.default
        limits.maxBytes = 4
        let big = ContextualDoor.diagnose(
            json: #"{"role":"admin"}"#, context: Self.plan, limits: limits)
        #expect(big.issues.map(\.code) == [.tooManyBytes])
    }

    @Test("XML, from a String and from bytes, and a document that does not parse")
    func xml() throws {
        let good = "<d><role>admin</role></d>"
        #expect(ContextualDoor.diagnose(xml: good, context: Self.plan).value?.role == "admin")
        #expect(try ContextualDoor.parse(xml: Array(good.utf8), context: Self.plan).role == "admin")
        let bad = ContextualDoor.diagnose(xml: "<d><role>admin</d>", context: Self.plan)
        #expect(bad.value == nil && !bad.isValid)
    }
}

// MARK: - Assayer's interpreter limits

@Suite("Assayer: shapes and depth")
struct AssayerPlanTests {

    @Sendable static func cyclic() -> Assayer<RawValue> {
        Assayer.lazy { Assayer.object([.init("next", cyclic(), optional: true)]) }
    }

    static func nested(_ depth: Int) -> RawValue {
        var v: RawValue = .mapping([])
        for _ in 0..<depth { v = .mapping([.init(key: "next", value: v)]) }
        return v
    }

    /// A runtime plan can refer to itself, which no macro-emitted schema can — so the
    /// interpreter charges depth itself. `RawValue` is handed over already built, so the
    /// parser's own depth limit is not what stops this.
    @Test("a self-referential plan stops at maxDepth instead of recursing without bound")
    func depth() {
        #expect(Self.cyclic().diagnose(Self.nested(5)).isValid)
        var limits = Limits.default
        limits.maxDepth = 16
        let d = Self.cyclic().diagnose(Self.nested(200), limits: limits)
        #expect(d.issues.map(\.code) == [.depthExceeded])
        #expect(d.issues.first?.params["maxDepth"] == .int(16))
    }

    @Test("an array plan given a scalar, and an object plan given an array")
    func shapes() {
        let ints = Assayer.array(of: Assayer.int)
        #expect(ints.diagnose(json: "3").issues.first?.params["expected"] == .string("array"))
        let object = Assayer.object([.init("a", .raw)])
        #expect(object.diagnose(json: "[1]").issues.first?.params["expected"] == .string("object"))
    }
}

// MARK: - Composed rules on numbers and collections

extension Rule {
    static let percentage = Rule.all(.min(0), .max(100))
    static let pair = Rule.all(.min(2), .max(2))
}

@Schema(formats: [.json, .yaml])
struct ComposedLeaf: Equatable {
    var i: Int
    var i64: Int64
}

@Schema(coerceScalars: true, formats: [.json, .yaml])
struct Composed: Equatable {
    @Validate(.percentage) var score: Int
    @Validate(.pair) var ends: [String]
    var id: UUID
    var grid: [[ComposedLeaf]] = []
    var named: [String: ComposedLeaf] = [:]
}

@Suite("Composed rules and nested trees")
struct ComposedRuleTests {

    static let id = "123e4567-e89b-12d3-a456-426614174000"

    @Test(".all applies to a number and to an element count")
    func all() {
        let d = Composed.diagnose(json: #"{"score":101,"ends":["a"],"id":"\#(Self.id)"}"#)
        #expect(d.issues.map(\.code) == [.tooLarge, .tooSmall])
        #expect(d.issues.map(\.path.pathDescription) == ["score", "ends"])
        #expect(d.issues.last?.params["unit"] == .string("items"))
    }

    @Test("true and false coerce to 1 and 0 from a tree")
    func boolToInt() throws {
        let v = try Composed.parse(yaml: "score: true\nends: [a, b]\nid: \(Self.id)\n")
        #expect(v.score == 1)
    }

    @Test("a UUID that is not a string, from a tree, is a mismatch naming uuid")
    func uuidMismatch() {
        let d = Composed.diagnose(yaml: "score: 1\nends: [a, b]\nid: [1]\n")
        #expect(d.issues.first?.path.pathDescription == "id")
        #expect(d.issues.first?.params["expected"] == .string("uuid"))
    }

    @Test("a schema nested inside an array of arrays and a dictionary carries its full path")
    func nestedPaths() throws {
        let yaml = """
            score: 1
            ends: [a, b]
            id: \(Self.id)
            grid:
              - - {i: 1, i64: 1}
                - {i: x, i64: 1}
            named:
              k: {i: 1, i64: y}
            """
        let d = Composed.diagnose(yaml: yaml)
        #expect(d.issues.map(\.path.pathDescription) == ["grid[0][1].i", "named.k.i64"])
    }
}
