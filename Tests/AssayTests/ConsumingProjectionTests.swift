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
