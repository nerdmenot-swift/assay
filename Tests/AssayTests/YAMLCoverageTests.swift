// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore
import AssayYAML

//===----------------------------------------------------------------------===//
// YAML: the scalar forms and refusals no document in the suite contained.
//
// The differential against libyaml covers what its corpus spells, and its corpus is
// configuration files. A plain scalar continued on the next line, a block scalar with a
// keep indicator or an explicit indent, a folded scalar with a more-indented line: each is
// valid YAML and its own branch, and none appeared. The expected values below were read
// off the parser and checked against YAML 1.2 §6–§8 by hand, one at a time.
//===----------------------------------------------------------------------===//

@Suite("YAML: scalar forms")
struct YAMLScalarFormTests {

    private func a(_ doc: String) throws -> String? {
        try YAML.parse(Array(doc.utf8))["a"]?.content
    }

    @Test("a plain scalar continues onto indented lines, folding as it goes")
    func plainContinuation() throws {
        // §7.3.3: a line break inside a plain scalar folds to a space…
        #expect(try a("a: one\n  two\n  three\n") == "one two three")
        // …and a blank line inside it is a line break that survives.
        #expect(try a("a: one\n\n  two\n") == "one\ntwo")
        // A comment line ends the scalar rather than joining it.
        #expect(try a("a: one\n  # c\n") == "one")
        #expect(try a("a: plain # comment\n") == "plain")
    }

    @Test("literal block scalars: keep, an explicit indent, and interior blank lines")
    func literal() throws {
        #expect(try a("a: |+\n  x\n\n") == "x\n\n")
        // `|2`: the content indent is stated, so deeper lines keep their extra spaces.
        #expect(try a("a: |2\n    x\n  y\n") == "  x\ny\n")
        #expect(try a("a: |\n  x\n\n  y\n") == "x\n\ny\n")
    }

    @Test("a folded scalar joins lines, keeps blank ones, and leaves a deeper line alone")
    func folded() throws {
        #expect(try a("a: >\n  x\n  y\n\n  z\n    indented\n  w\n") == "x y\nz\n  indented\nw\n")
    }

    @Test("double-quoted escapes: \\x, \\u and \\U")
    func escapes() throws {
        #expect(try a(#"a: "\x41\u00e9\U0001F600""# + "\n") == "Aé😀")
    }

    @Test("directives are skipped, not honoured, and do not start a document")
    func directive() throws {
        #expect(try a("%YAML 1.2\n---\na: 1\n") == "1")
    }

    @Test("an anchor on a flow mapping and on a quoted scalar resolves through its alias")
    func anchors() throws {
        let m = try YAML.parse(Array("a: &m {b: 1}\nc: *m\n".utf8))
        #expect(m["c"]?["b"]?.content == "1")
        let q = try YAML.parse(Array("a: &q \"quoted\"\nc: *q\n".utf8))
        #expect(q["c"]?.content == "quoted")
    }

    @Test("a merge key inside a flow mapping merges, and the local key wins")
    func flowMerge() throws {
        let n = try YAML.parse(Array("base: &b {x: 1, y: 0}\na: {<<: *b, y: 2}\n".utf8))
        #expect(n["a"]?["x"]?.content == "1")
        #expect(n["a"]?["y"]?.content == "2")
    }
}

@Suite("YAML: refusals")
struct YAMLRefusalTableTests {

    @Test(
        "each malformed document is refused under its own code, at the byte that is wrong",
        arguments: [
            ("a: *nope\n", "yaml_undefined_alias", 8),
            ("a: [*nope]\n", "yaml_undefined_alias", 9),
            ("a: \"\\xZZ\"\n", "yaml_bad_escape", 9),
            ("a: [1, 2\n", "yaml_unterminated_flow_sequence", 9),
            ("a: {b: 1\n", "yaml_unterminated_flow_mapping", 9),
            ("a: {b 1}\n", "yaml_expected_colon", 7),
            ("a: &x *y\n", "yaml_anchor_on_alias", 6),
            ("? complex\n- x\n", "yaml_expected_value_indicator", 10)
        ])
    func refused(doc: String, code: String, at: Int) {
        var sink = IssueSink(limits: .default)
        _ = YAML.decodeAll(Array(doc.utf8), into: &sink, limits: .default)
        #expect(sink.issues.map(\.code) == [.custom(code)], "\(doc)")
        #expect(sink.issues.first?.location.map { Int($0.lo) } == at, "\(doc)")
    }

    @Test("a flow collection cut off by the end of the input, with no newline to stop at")
    func endOfInput() {
        for (doc, code) in [
            ("a: [1, 2", "yaml_unterminated_flow_sequence"),
            ("a: {b: 1", "yaml_unterminated_flow_mapping")
        ] {
            var sink = IssueSink(limits: .default)
            _ = YAML.decodeAll(Array(doc.utf8), into: &sink, limits: .default)
            #expect(sink.issues.map(\.code) == [.custom(code)], "\(doc)")
        }
    }

    @Test("a complex key inside a flow mapping has no place in a schema's tree")
    func complexKeyThroughTheSchemaDoor() {
        let d = MergedHolder.diagnose(yaml: "merged: {[1, 2]: v}\n")
        #expect(d.issues.map(\.code) == [.yamlUnrepresentableKey])
    }

    @Test("anchors inside a flow sequence: on a mapping, on a quoted scalar, and aliased back")
    func anchorsInFlow() throws {
        let n = try YAML.parse(Array("a: [&m {b: 1}, &q \"s\", *m, *q]\n".utf8))
        let items = try #require(n["a"]?.sequence)
        #expect(items.count == 4)
        #expect(items[2] == items[0] && items[3].content == "s")
    }

    @Test("parse() wants exactly one document")
    func oneDocument() {
        #expect(throws: AssayError.self) { _ = try YAML.parse([]) }
        do {
            _ = try YAML.parse(Array("a: 1\n---\nb: 2\n".utf8))
            Issue.record("expected a throw")
        } catch {
            #expect(error.issues.map(\.code) == [.yamlMultipleDocuments])
            #expect(error.issues.first?.params["count"] == .int(2))
        }
        // parseAll is the door for a stream, and it throws what the parser found.
        #expect(throws: AssayError.self) { _ = try YAML.parseAll(Array("a: [1\n".utf8)) }
    }

    @Test("the document-level limits: maxBytes and invalid UTF-8")
    func limits() {
        var small = Limits.default
        small.maxBytes = 4
        var sink = IssueSink(limits: small)
        #expect(YAML.decodeAll(Array("a: 12345\n".utf8), into: &sink, limits: small).isEmpty)
        #expect(sink.issues.map(\.code) == [.tooManyBytes])

        var sink2 = IssueSink(limits: .default)
        _ = YAML.decodeAll(Array("a: ".utf8) + [0xFF, 0x0A], into: &sink2, limits: .default)
        #expect(sink2.issues.map(\.code) == [.invalidUTF8])
        #expect(sink2.issues.first?.params["offset"] == .int(3))
    }
}

@Suite("YAML.Node as a value")
struct YAMLNodeValueTests {

    static func node(_ doc: String) throws -> YAML.Node { try YAML.parse(Array(doc.utf8)) }

    @Test("each accessor is nil for the other two shapes")
    func accessors() throws {
        let n = try Self.node("s: x\nq: [1, 2]\nm: {k: v}\n")
        let s = try #require(n["s"]), q = try #require(n["q"]), m = try #require(n["m"])
        #expect(s.sequence == nil && s.mapping == nil && s["k"] == nil && s[0] == nil)
        #expect(q.scalar == nil && q.content == nil && q.mapping == nil && q[9] == nil)
        #expect(m.scalar == nil && m.sequence == nil && m["absent"] == nil)
        // Resolution is a property of scalars; a collection resolves to nothing.
        #expect(q.resolvedBool == nil && q.resolvedInt == nil && q.resolvedDouble == nil)
        #expect(!q.isNull && !m.isNull)
        #expect(s.resolvedBool == nil)
    }

    @Test("a mapping is addressable by a node key, which is the only way to reach a complex one")
    func nodeKeys() throws {
        let n = try Self.node("a: {[1, 2]: v, plain: w}\n")
        let inner = try #require(n["a"])
        let key = try #require(inner.mapping?.first?.key)
        #expect(key.sequence?.count == 2)
        #expect(inner[node: key]?.content == "v")
        #expect(inner[node: .sequence([])] == nil)
        #expect(key[node: key] == nil)  // not a mapping
    }

    @Test("pairs and nodes hash by value, and an array literal builds a sequence")
    func hashing() throws {
        let a = try Self.node("x: {k: v}\n"), b = try Self.node("x: {k: v}\n")
        #expect(Set([a, b]).count == 1)
        #expect(Set(try #require(a["x"]?.mapping) + (try #require(b["x"]?.mapping))).count == 1)
        let literal: YAML.Node = [a, b]
        #expect(literal.sequence?.count == 2)
    }

    /// `RawValue` keys are strings. A node tree with a sequence or mapping as a KEY has no
    /// projection, at any depth — and the answer is nil for the whole value, not a tree
    /// with that member quietly missing.
    @Test("a tree with a complex key has no RawValue projection, however deep the key is")
    func noProjection() throws {
        #expect(RawValue(try Self.node("a: {[1, 2]: v}\n")) == nil)
        #expect(RawValue(try Self.node("a:\n  - {[1, 2]: v}\n")) == nil)
        #expect(RawValue(try Self.node("a:\n  b:\n    - x\n    - {{k: v}: w}\n")) == nil)
        #expect(RawValue(try Self.node("a: {b: [1, 2]}\n")) != nil)
    }
}

@Schema(formats: [.yaml])
struct MergedWide: Equatable {
    var k0: Int
    var k29: Int
    var extra: Int
}

@Schema(formats: [.yaml])
struct MergedHolder: Equatable {
    var merged: MergedWide
}

@Suite("YAML: merge keys at size")
struct YAMLMergeScaleTests {

    /// Past 24 keys a merge dedupes through a set instead of a linear scan. Same answer;
    /// this is the document that takes the other route, on both builders.
    @Test("a merge of thirty keys keeps the local value for a key both sides define")
    func wideMerge() throws {
        let base = (0..<30).map { "  k\($0): \($0)" }.joined(separator: "\n")
        let doc = "base: &b\n\(base)\nmerged:\n  <<: *b\n  k0: 100\n  extra: 7\n"

        let node = try YAML.parse(Array(doc.utf8))
        #expect(node["merged"]?.mapping?.count == 31)
        #expect(node["merged"]?["k0"]?.content == "100")
        #expect(node["merged"]?["k29"]?.content == "29")

        let v = try MergedHolder.parse(yaml: doc)
        #expect(v.merged == MergedWide(k0: 100, k29: 29, extra: 7))
    }

    @Test("a merge from a SEQUENCE of mappings takes each in order, earlier ones winning")
    func sequenceMerge() throws {
        let a = (0..<15).map { "  k\($0): \($0)" }.joined(separator: "\n")
        let b = (15..<30).map { "  k\($0): \($0)" }.joined(separator: "\n")
        let doc = "a: &a\n\(a)\nb: &b\n\(b)\n  k0: -1\nmerged:\n  <<: [*a, *b]\n  extra: 7\n"
        let v = try MergedHolder.parse(yaml: doc)
        #expect(v.merged == MergedWide(k0: 0, k29: 29, extra: 7))
    }
}

@Suite("YAML: keys that are not plain scalars")
struct YAMLKeyFormTests {

    @Test("a quoted key with no colon after it is refused")
    func quotedKeyNoColon() {
        var sink = IssueSink(limits: .default)
        _ = YAML.decodeAll(Array("x: 1\n\"key\" value\n".utf8), into: &sink, limits: .default)
        #expect(!sink.isValid)
    }

    @Test("a flow collection as a block key is a complex key: a node, and no schema value")
    func flowKeys() throws {
        let seq = try YAML.parse(Array("x: 1\n[a, b]: v\n".utf8))
        #expect(seq.mapping?.last?.key.sequence?.count == 2)
        let map = try YAML.parse(Array("x: 1\n{a: b}: v\n".utf8))
        #expect(map.mapping?.last?.key.mapping?.count == 1)
        #expect(RawValue(seq) == nil && RawValue(map) == nil)
    }
}
