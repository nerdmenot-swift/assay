// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Foundation
import Assay
import AssayCore
import AssayFoundation
import AssayTOML
import AssayYAML
import AssayPlist

//===----------------------------------------------------------------------===//
// The last reachable arms, one or two lines each. Nothing here shares a theme beyond
// that: every one is a line a specific input reaches, and had no such input.
//===----------------------------------------------------------------------===//

@Schema(formats: [.yaml])
struct PlainInner: Equatable { var team: String }

@Schema(context: TenantContext.self, formats: [.yaml])
struct ContextualOuter: Equatable {
    var role: String
    var inner: PlainInner
}

@Schema
struct Shouted: Equatable {
    @Preprocess(.uppercase) @Validate(.min(5)) var code: String
    var ratio: Float
    var tiny: Double
    @Validate(.email) var email: String
}

@Suite("Remaining arms: decoding")
struct RemainderDecodeTests {

    static let plan = TenantContext(availableRoles: ["admin"], maximumSeats: 1)

    @Test("a contextual type holding a plain one, from YAML: the context is absorbed, not required")
    func contextAbsorbedOnTheTreePath() throws {
        let v = try ContextualOuter.parse(
            yaml: "role: admin\ninner:\n  team: core\n", context: Self.plan)
        #expect(v == ContextualOuter(role: "admin", inner: PlainInner(team: "core")))
        let bad = ContextualOuter.diagnose(yaml: "role: [1\n", context: Self.plan)
        #expect(bad.value == nil && !bad.isValid)
    }

    @Test("@Preprocess(.uppercase) runs before the rules, on ASCII letters only")
    func uppercase() throws {
        let v = try Shouted.parse(
            json:
                #"{"code":"abçde","ratio":1.5,"tiny":0.0000000000000000000000000,"email":"a@b.co"}"#
        )
        #expect(v.code == "ABçDE")
        // More than nineteen digits, all zero: the slow path, and honestly zero.
        #expect(v.tiny == 0 && v.ratio == 1.5)
    }

    @Test("a Float that is not a number, and an email with a character no local part allows")
    func mismatches() {
        let d = Shouted.diagnose(json: #"{"code":"abcde","ratio":"x","tiny":0,"email":"a b@c.co"}"#)
        #expect(d.issues.map(\.code) == [.typeMismatch, .invalidEmail])
        #expect(d.issues.map(\.path.pathDescription) == ["ratio", "email"])
    }

    @Test("a control character in a rejected value is escaped in the JSON render")
    func jsonRenderEscapes() {
        let d = Shouted.diagnose(json: #"{"code":"a\u0001","ratio":1,"tiny":0,"email":"a@b.co"}"#)
        #expect(d.issues.map(\.code) == [.tooSmall])
        #expect(d.render(.json).contains(#"A\u0001"#))
    }

    @Test("a wrapper field given malformed JSON reports the document, not the wrapper")
    func wrapperOnMalformedInput() {
        let d = MailAccount.diagnose(json: #"{"email": tru, "name": "n"}"#)
        #expect(d.value == nil && !d.isValid)
        #expect(d.issues.allSatisfy { $0.code != .assayerConversionFailed })
    }

    @Test("a tagged union: an empty object has no tag, and a malformed one is malformed")
    func discriminatorScan() {
        let empty = GoldenTagged.diagnose(json: "{}")
        #expect(empty.issues.map(\.code) == [.missing])
        let malformed = GoldenTagged.diagnose(json: "{1:2}")
        #expect(malformed.issues.map(\.code) == [.malformedDocument])
    }

    @Test("a non-JSON body that does not parse, on a type that can also read JSON")
    func malformedTreeBody() {
        let d = DataBody.diagnose(
            body: Array("title: [1\n".utf8), contentType: "application/yaml",
            accepting: [.json, .yaml], sourceName: "req")
        #expect(d.value == nil && !d.isValid)
        #expect(d.sourceName == "req")
    }

    @Test("AssayError names its source")
    func errorSourceName() {
        do {
            _ = try OneString.parse(json: Array("{".utf8), sourceName: "body.json")
            Issue.record("expected a throw")
        } catch {
            #expect((error as? AssayError)?.sourceName == "body.json")
        }
    }
}

@Suite("Remaining arms: values and options")
struct RemainderValueTests {

    @Test("an empty EncodedBytes is empty, and lends an empty buffer")
    func emptyEncodedBytes() {
        let e = EncodedBytes()
        #expect(e.isEmpty && e.count == 0)
        #expect(e.withUnsafeBytes { $0.count } == 0)
        #expect(e.text() == "")
    }

    @Test("the option values the macro reads as syntax are ordinary values too")
    func options() {
        let tag: Discriminator = "type"
        #expect(tag == "type" && tag != .untagged && tag != "kind")
        #expect(SchemaFormats(rawValue: 3) == [.json, .yaml])
        #expect(SchemaFormats.all.contains(.toml))
    }

    @Test("RawValue: accessors on the wrong case, and hashing across every case")
    func rawValue() {
        let s: RawValue = "x"
        #expect(s.bool == nil && s.int == nil && s.mapping == nil)
        let all: [RawValue] = [nil, true, 1, 1.5, "x", [1], .mapping([.init(key: "k", value: 1)])]
        #expect(Set(all).count == all.count)
        #expect(Set(all + all).count == all.count)
    }

    private func issues(_ value: Double, _ rule: Rule) -> [IssueCode] {
        var sink = IssueSink(limits: .default)
        _assayValidate(value, [rule], override: nil, field: "f", at: nil, path: [], &sink)
        return sink.issues.map(\.code)
    }

    @Test("a date rule whose bound is not a date fails every value, in each form")
    func invalidBounds() {
        #expect(issues(0, .after("not a date")) == [.invalidRuleDate])
        #expect(issues(0, .between("not a date", "2030-01-01")) == [.invalidRuleDate])
        #expect(issues(0, .between("2020-01-01", "nope")) == [.invalidRuleDate])
        #expect(issues(0, .after("1960-01-01")).isEmpty)
    }

    @Test("a message-only rule checks nothing on a number; a string rule nothing on a count")
    func inapplicable() {
        #expect(issues(1, "only a message").isEmpty)
        var sink = IssueSink(limits: .default)
        _assayValidate(
            countOf: [true, false], [.email, .min(1)], override: nil, field: "f", at: nil,
            path: [], &sink)
        #expect(sink.issues.isEmpty)
    }
}

@Suite("Remaining arms: formats")
struct RemainderFormatTests {

    private func yamlCodes(_ doc: String) -> [IssueCode] {
        var sink = IssueSink(limits: .default)
        _ = YAML.decodeAll(Array(doc.utf8), into: &sink, limits: .default)
        return sink.issues.map(\.code)
    }

    @Test("a flow collection that ends right after its opener or a comma")
    func flowAtEndOfInput() {
        #expect(yamlCodes("a: [") == [.yamlUnterminatedFlowSequence])
        #expect(yamlCodes("a: [1,") == [.yamlUnterminatedFlowSequence])
        #expect(yamlCodes("a: {") == [.yamlUnterminatedFlowMapping])
        #expect(yamlCodes("a: {b: 1,") == [.yamlUnterminatedFlowMapping])
    }

    @Test("a continuation line that starts with an indicator ends the plain scalar")
    func indicatorEndsContinuation() {
        // `&x two` is not more of "one": it would be an anchored node, which has no place
        // after a scalar, so the document is refused rather than the text being absorbed.
        #expect(!yamlCodes("a: one\n  &x two\n").isEmpty)
    }

    @Test("a schema value followed by a comment: the caret covers the value, not the comment")
    func spanStopsBeforeAComment() {
        let doc = "name: n   # the name\ncount: many   # not a number\n"
        let d = TreeWarns.diagnose(yaml: doc)
        #expect(d.issues.map(\.code) == [.typeMismatch])
        let span = d.issues.first?.location
        #expect(span.map { Int($0.len) } == "many".utf8.count)
        #expect(span.map { Int($0.lo) } == doc.utf8.count - "many   # not a number\n".utf8.count)
    }

    @Test("YAML writes a control character as \\xNN, and reads it back")
    func yamlControlCharacter() throws {
        let v = Collides(id: "a\u{01}b", rest: [:])
        let text = try v.yamlText()
        #expect(text.contains(#"\x01"#))
        #expect(try Collides.parse(yaml: text) == v)
    }

    @Test("TOML through the schema door: maxBytes, and extending an array as if it were a table")
    func toml() {
        var small = Limits.default
        small.maxBytes = 4
        let big = TOMLServer.diagnose(toml: "ip = \"1.1.1.1\"\nrole = \"a\"\n", limits: small)
        #expect(big.issues.map(\.code) == [.tooManyBytes])

        var sink = IssueSink(limits: .default)
        #expect(TOML.decode(Array("a = [1]\na.b = 2\n".utf8), into: &sink) == nil)
        #expect(sink.issues.map(\.code) == [.tomlNotATable])
        #expect(sink.issues.first?.params["key"] == .string("a"))
    }

    @Test("TOML floats with a signed exponent")
    func tomlExponents() throws {
        let doc = try TOML.parse("a = 1.5e-3\nb = 2E+2\nc = -1e-2\n")
        #expect(
            doc["a"] == .double(0.0015) && doc["b"] == .double(200) && doc["c"] == .double(-0.01))
    }

    @Test("a binary plist string that opens with a LOW surrogate is refused")
    func loneLowSurrogate() {
        var b = BPlistBuilder()
        let top = b.add([0x61, 0xDC, 0x00])
        var sink = IssueSink(limits: .default)
        #expect(Plist.decode(b.finish(top: top), into: &sink, limits: .default) == nil)
        #expect(sink.issues.map(\.code) == [.plistBadString])
    }

    @Test("JSON.Value from an empty mapped file is an error, not a crash on a nil base")
    func emptyMappedValue() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("assay-empty-\(UInt64.random(in: 0..<(.max))).json")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: AssayError.self) { _ = try JSON.Value.parse(mmapped: url) }
    }

    @Test("a directory can be opened and cannot be mapped")
    func directory() {
        #expect(throws: MappedFileError.self) {
            _ = try MappedFile.open(path: FileManager.default.temporaryDirectory.path)
        }
    }
}
