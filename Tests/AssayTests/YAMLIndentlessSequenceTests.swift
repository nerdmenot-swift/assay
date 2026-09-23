// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayYAML

//===----------------------------------------------------------------------===//
// The INDENTLESS block sequence: a mapping value's sequence at the KEY's indentation.
//
//     items:
//     - a
//     - b
//
// Valid YAML 1.2 (§8.2.1), and how Kubernetes manifests, GitHub Actions workflows and
// docker-compose files are commonly written. Found 2026-09-19 by the portable scaling test,
// whose fixture used this form, and fixed the same day. Until then two things were wrong,
// and the second was the serious one:
//   * `items:\n- a\n- b\n` and `items:\n- name: x\n  n: 0\n` were REFUSED;
//   * `items:\n- name: x\n` was ACCEPTED AND WRONG, as `{items: "", "- name": "x"}` — the dash
//     line went back to the mapping loop as a KEY, and a schema then reported `items` as
//     the wrong type rather than the document as malformed.
// The Yams differential never caught it because its corpus never used the form; it does
// now (`indentless-*` in Benchmarks/Sources/DiffFuzz/OracleCorpus.swift).
//===----------------------------------------------------------------------===//

@Schema(formats: .all) struct IndentlessDoc: Equatable { var items: [String] }
@Schema(formats: .all) struct IndentlessRow: Equatable { var name: String }
@Schema(formats: .all) struct IndentlessRows: Equatable { var items: [IndentlessRow] }
@Schema(formats: .all) struct IndentlessTwo: Equatable { var items: [String]; var copy: [String] }
@Schema(formats: .all) struct IndentlessNext: Equatable { var items: [String]; var next: Int }
@Schema(formats: .all) struct K8sPort: Equatable { var containerPort: Int }
@Schema(formats: .all) struct K8sContainer: Equatable {
    var name: String; var ports: [K8sPort] = []
}
@Schema(formats: .all) struct K8sSpec: Equatable { var containers: [K8sContainer] }
@Schema(formats: .all) struct K8sPod: Equatable { var spec: K8sSpec }

@Suite("YAML — indentless block sequences")
struct YAMLIndentlessSequenceTests {

    @Test("the indented form decodes, as it always did")
    func indentedWorks() throws {
        #expect(
            try IndentlessDoc.parse(yaml: "items:\n  - a\n  - b\n")
                == IndentlessDoc(items: ["a", "b"]))
        #expect(
            try IndentlessRows.parse(yaml: "items:\n  - name: x\n")
                == IndentlessRows(items: [IndentlessRow(name: "x")]))
    }

    @Test("a sequence of scalars at the key's indentation")
    func scalars() throws {
        #expect(
            try IndentlessDoc.parse(yaml: "items:\n- a\n- b\n") == IndentlessDoc(items: ["a", "b"]))
    }

    @Test("a sequence of mappings at the key's indentation")
    func mappings() throws {
        #expect(
            try IndentlessRows.parse(yaml: "items:\n- name: x\n- name: y\n")
                == IndentlessRows(items: [IndentlessRow(name: "x"), IndentlessRow(name: "y")]))
    }

    @Test("the one-entry form, which was silently mis-parsed, has one key")
    func silentMisparse() throws {
        let node = try YAML.parse(Array("items:\n- name: x\n".utf8))
        guard case .mapping(let pairs) = node else { Issue.record("not a mapping"); return }
        #expect(pairs.count == 1, "\(pairs.map(\.key))")
        guard case .sequence(let xs)? = pairs.first?.value else {
            Issue.record("items is not a sequence"); return
        }
        #expect(xs.count == 1)
    }

    @Test("the sequence ends at the next key, and an anchor on the key covers it")
    func boundaries() throws {
        #expect(
            try IndentlessTwo.parse(yaml: "items: &l\n- a\n- b\ncopy: *l\n")
                == IndentlessTwo(items: ["a", "b"], copy: ["a", "b"]))
        #expect(
            try IndentlessNext.parse(yaml: "items:\n# note\n- a\nnext: 1\n")
                == IndentlessNext(items: ["a"], next: 1))
    }

    @Test("a Kubernetes-shaped document: indentless at two levels")
    func kubernetesShape() throws {
        let pod = try K8sPod.parse(
            yaml: """
                spec:
                  containers:
                  - name: web
                    ports:
                    - containerPort: 80
                  - name: side
                """)
        #expect(
            pod.spec.containers == [
                K8sContainer(name: "web", ports: [K8sPort(containerPort: 80)]),
                K8sContainer(name: "side")
            ])
    }

    @Test("a mapping at the key's column is still a sibling, not a value")
    func siblingNotValue() throws {
        let node = try YAML.parse(Array("a:\nb: 1\n".utf8))
        guard case .mapping(let pairs) = node else { Issue.record("not a mapping"); return }
        #expect(pairs.count == 2)
    }
}
