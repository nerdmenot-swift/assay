// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore
@testable import AssayYAML
@testable import AssayTOML
@testable import AssayXML

//===----------------------------------------------------------------------===//
// `RawValue(consuming:)` moves a YAML, TOML or XML tree's strings into the projection instead of
// retaining them (docs/EFFICIENCY.md). It is a second implementation of the same function,
// so the borrowing `RawValue(_:)` is its oracle: identical output on every shape, including
// the two a shape flag can get wrong — an EMPTY mapping must not come back as an empty
// sequence — and the same refusal of a non-scalar key.
//===----------------------------------------------------------------------===//

@Suite struct YAMLConsumingProjectionTests {

    static let documents: [String] = [
        "a: 1\nb: [x, y, {c: true}]\nd: {}\ne: []\nf: ~\ng: 'q'\n",
        "- {}\n- []\n- [[], {}]\n- name: n\n  tags:\n  - t1\n  - t2\n",
        "outer:\n  inner:\n    deep: [1, 2.5, .inf, \"s\"]\n  empty: {}\n",
        "{}",
        "[]",
        "plain scalar",
        "base: &b {k: v}\nuse: *b\n",
    ]

    @Test(arguments: documents)
    func matchesTheBorrowingProjection(_ text: String) throws {
        var sink = IssueSink()
        let docs = YAML.decodeAll(Array(text.utf8), into: &sink, limits: .default)
        #expect(sink.isValid)
        let doc = try #require(docs.first)
        let borrowed = RawValue(doc)
        let moved = RawValue(consuming: doc)
        #expect(borrowed != nil)
        #expect(moved == borrowed)
    }

    @Test func refusesANonScalarKeyLikeTheBorrowingForm() throws {
        var sink = IssueSink()
        let docs = YAML.decodeAll(Array("? [a, b]\n: c\n".utf8), into: &sink, limits: .default)
        let doc = try #require(docs.first)
        #expect(RawValue(doc) == nil)
        #expect(RawValue(consuming: doc) == nil)
    }

    @Test func emptyMappingStaysAMapping() throws {
        var sink = IssueSink()
        let doc = try #require(YAML.decodeAll(Array("{}".utf8), into: &sink,
                                              limits: .default).first)
        guard case .mapping(let m)? = RawValue(consuming: doc) else {
            Issue.record("expected an empty mapping"); return
        }
        #expect(m.isEmpty)
    }
}

@Suite struct TOMLConsumingProjectionTests {

    static let documents: [String] = [
        "title = \"x\"\n[[items]]\nid = 1\ntags = [\"a\", \"b\"]\n[items.sub]\nk = 2\n[[items]]\nid = 2\ntags = []\n",
        "a = {}\nb = []\nc = [[1, 2], [], [{x = 1}]]\nd = 1979-05-27T07:32:00Z\n",
        "",
        "[t]\n[t.u]\nv = 1.5\nw = true\n",
    ]

    @Test(arguments: documents)
    func matchesTheBorrowingProjection(_ text: String) throws {
        var sink = IssueSink()
        let node = try #require(TOML.decode(Array(text.utf8), into: &sink))
        #expect(sink.isValid)
        #expect(RawValue(consuming: node) == RawValue(node))
    }

    /// The struct door skips the node tree entirely (`TOML.decodeRaw`, which drains the
    /// builders into the projection); it must build exactly what projecting the tree does.
    @Test(arguments: documents)
    func directProjectionMatchesTheTree(_ text: String) throws {
        var sink = IssueSink()
        let node = try #require(TOML.decode(Array(text.utf8), into: &sink))
        var rawSink = IssueSink()
        let raw = try #require(TOML.decodeRaw(Array(text.utf8), into: &rawSink, limits: .default))
        #expect(raw == RawValue(node))
        #expect(rawSink.isValid)
    }
}

@Suite struct XMLConsumingProjectionTests {

    static let documents: [String] = [
        "<doc><items><f0>a</f0><f1>b</f1></items><items><f0>c</f0><f1/></items></doc>",
        "<r id=\"7\" kind=\"x\"><name>n</name>  <tag>t1</tag><tag>t2</tag></r>",
        "<r>text <b>bold</b> tail<![CDATA[<raw>]]><!-- c --><?pi data?></r>",
        "<r><a>one<!-- c -->two<![CDATA[three]]></a><e/><w>   </w></r>",
        "<r xmlns:p=\"urn:p\"><p:x p:attr=\"v\">1</p:x></r>",
        "<only>leaf</only>",
        "<empty/>",
    ]

    @Test(arguments: documents)
    func matchesTheBorrowingProjection(_ text: String) throws {
        var sink = IssueSink()
        let doc = try #require(XML.decode(Array(text.utf8), into: &sink))
        #expect(sink.isValid)
        #expect(RawValue(consuming: doc) == RawValue(doc))
    }
}

/// `RawValue(resolving:)` sends a plain scalar whose first byte cannot start a non-string
/// straight to `.string`; the full resolver is the oracle. Every printable first byte, each
/// special spelling, numbers in every form `Int64` and `Double` accept, and the words
/// `Double` alone would take (`inf`, `nan`, `infinity`) in several cases.
@Suite struct YAMLResolutionFastPathTests {

    static var scalars: [String] {
        var out: [String] = ["", "~", "null", "Null", "NULL", "nul", "true", "True", "TRUE",
            "tRue", "false", "False", "FALSE", ".inf", ".Inf", ".INF", "+.inf", "-.inf",
            "-.Inf", ".nan", ".NaN", ".NAN", "inf", "Inf", "INF", "nan", "NaN", "infinity",
            "Infinity", "-infinity", "+infinity", "0", "-0", "+0", "12", "-12", "+12",
            "007", "1_000", "0x1F", "0x1p3", "0o17", "1e3", "1E-3", "1e309", "1e-400",
            "0.0e-400", ".5", "-.5", "+.5", "5.", "1.2.3", "12abc", " 12", "12 ", "-",
            "+", ".", "e3", "E3", "yes", "no", "on", "off", "Y", "n", "t", "f"]
        for b in UInt8(0x21)...UInt8(0x7E) {
            let c = String(UnicodeScalar(b))
            out.append(c); out.append(c + "1"); out.append(c + "abc"); out.append(c + "inf")
        }
        out += ["é", "éa", "日本", "💥1"]
        return out
    }

    @Test func fastPathAgreesWithTheFullResolver() {
        for text in Self.scalars {
            for tag: String? in [nil, "!!str", "!!int", "!!float", "!!bool", "!!null", "!Foo"] {
                let s = YAML.Scalar(content: text, style: .plain, tag: tag)
                let fast = RawValue(resolving: s)
                let full = RawValue(_resolvingCoreSchema: s)
                #expect(fast == full || (fast.isNaN && full.isNaN), "\(text) tag \(tag ?? "nil")")
            }
        }
    }
}

private extension RawValue {
    var isNaN: Bool { if case .double(let d) = self { return d.isNaN }; return false }
}

/// The YAML struct doors parse straight to `RawValue` (`YAML.decodeAllRaw`, one parser generic
/// over what it builds — `YAMLBuilder.swift`). It must build exactly what projecting the node
/// tree builds, on every shape, and refuse the same documents with the same code.
@Suite struct YAMLDirectDoorTests {

    static var documents: [String] {
        YAMLConsumingProjectionTests.documents + [
            "a: 1\nb:\n  c: [1, 2, {d: e}]\n",
            "base: &b {k: v, n: 1}\nuse:\n  <<: *b\n  k: own\n",
            "seq:\n- <<: &m {x: 1}\n- {}\n",
            "tagged: !!str 12\nplain: 12\nquoted: \"12\"\n",
            "l: |\n  one\n  two\nf: >\n  folded\n  text\n",
            "empty:\nnull_: ~\nzero: 0\nneg: -1\nbig: 1e309\n",
            "# only a comment\n",
            "- - 1\n  - 2\n- k: v\n",
        ]
    }

    @Test(arguments: documents)
    func matchesTheProjectedTree(_ text: String) throws {
        let bytes = Array(text.utf8)
        var treeSink = IssueSink()
        let docs = YAML.decodeAll(bytes, into: &treeSink, limits: .default)
        var rawSink = IssueSink()
        let direct = YAML.decodeAllRaw(bytes, into: &rawSink, limits: .default)

        #expect(direct.count == docs.count)
        #expect(rawSink.issues.map(\.code) == treeSink.issues.map(\.code))
        for (d, tree) in zip(direct, docs) {
            #expect(d == RawValue(tree))
        }
    }

    /// A key `RawValue` cannot hold: the tree keeps it, the direct door refuses it, and the
    /// code is the one the entry point used to report after the projection failed.
    @Test func refusesAnUnrepresentableKeyWithTheSameCode() {
        let text = "? [a, b]\n: c\n"
        var treeSink = IssueSink()
        let docs = YAML.decodeAll(Array(text.utf8), into: &treeSink, limits: .default)
        #expect(treeSink.isValid)
        #expect(docs.first.flatMap { RawValue($0) } == nil)

        var rawSink = IssueSink()
        _ = YAML.decodeAllRaw(Array(text.utf8), into: &rawSink, limits: .default)
        #expect(rawSink.issues.first?.code == .yamlUnrepresentableKey)
    }

    /// And the struct door reports it rather than decoding something wrong.
    @Test func structDoorReportsTheUnrepresentableKey() {
        let d = YRoundTrip.diagnose(yaml: "? [a, b]\n: c\n")
        #expect(d.value == nil)
        #expect(d.issues.contains { $0.code == .yamlUnrepresentableKey })
    }
}

@Schema(formats: .all) struct YRoundTrip: Equatable { var a: String? }
