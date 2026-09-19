// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayYAML

//===----------------------------------------------------------------------===//
// KNOWN BUG, pinned rather than fixed: the INDENTLESS block sequence.
//
// YAML lets a block sequence that is a mapping's value sit at the SAME indentation as its key:
//
//     items:
//     - a
//     - b
//
// That is valid YAML 1.2, and it is how Kubernetes manifests, GitHub Actions workflows and
// docker-compose files are commonly written. Assay's parser only accepts the sequence
// indented under the key. Found 2026-09-19 by the portable scaling test, whose YAML fixture
// used this form; the Yams differential never caught it because the corpus never uses it.
//
// Two failure modes, and the second is the serious one:
//   * `items:\n- a\n- b\n` and `items:\n- name: x\n  n: 0\n` are REJECTED — loud, and a user
//     can work around it by indenting.
//   * `items:\n- name: x\n` is ACCEPTED AND WRONG: it parses as `{items: "", "- name": "x"}`.
//     A decode against a schema then reports `items` as the wrong type rather than the
//     document as malformed, which points the user at the wrong line.
//
// `withKnownIssue` keeps both visible: the suite passes today, and the moment the parser
// accepts these correctly the known issue stops occurring and the test FAILS, asking for
// this wrapper to be removed.
//===----------------------------------------------------------------------===//

@Schema(formats: .all) struct IndentlessDoc: Equatable { var items: [String] }
@Schema(formats: .all) struct IndentlessRow: Equatable { var name: String }
@Schema(formats: .all) struct IndentlessRows: Equatable { var items: [IndentlessRow] }

@Suite("YAML — indentless block sequences (known bug)")
struct YAMLIndentlessSequenceTests {

    @Test("the indented form decodes, which is what the known issue is measured against")
    func indentedWorks() throws {
        #expect(try IndentlessDoc.parse(yaml: "items:\n  - a\n  - b\n") ==
                IndentlessDoc(items: ["a", "b"]))
        #expect(try IndentlessRows.parse(yaml: "items:\n  - name: x\n") ==
                IndentlessRows(items: [IndentlessRow(name: "x")]))
    }

    @Test("a sequence of scalars at the key's indentation")
    func scalars() {
        withKnownIssue("indentless block sequences are not parsed — see file header") { () throws in
            #expect(try IndentlessDoc.parse(yaml: "items:\n- a\n- b\n") ==
                    IndentlessDoc(items: ["a", "b"]))
        }
    }

    @Test("a sequence of mappings at the key's indentation")
    func mappings() {
        withKnownIssue("indentless block sequences are not parsed — see file header") { () throws in
            #expect(try IndentlessRows.parse(yaml: "items:\n- name: x\n- name: y\n") ==
                    IndentlessRows(items: [IndentlessRow(name: "x"), IndentlessRow(name: "y")]))
        }
    }

    @Test("the one-entry form is accepted and MIS-PARSED, not refused")
    func silentMisparse() throws {
        withKnownIssue("parses as {items: \"\", \"- name\": \"x\"} — see file header") { () throws in
            let node = try YAML.parse(Array("items:\n- name: x\n".utf8))
            guard case .mapping(let pairs) = node else { Issue.record("not a mapping"); return }
            #expect(pairs.count == 1, "\(pairs.map(\.key))")
        }
    }
}
