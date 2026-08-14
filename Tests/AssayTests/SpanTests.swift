// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Carets for YAML and XML. ROADMAP §12, now closed.
//
// The caret is this library's headline claim, and until now two of the three formats did
// not get one where it counts. A YAML *syntax* error always carried a span, because the
// parser reports it with the cursor in hand. A YAML *schema* issue did not: YAML and XML
// build a node model first, project it to `RawValue`, and decode from that — and the byte
// offset was gone by the time a `@Validate` rule ran. The identical failure rendered with
// a caret through JSON and without one through YAML.
//
// The fix is one optional field, `RawValue.Member.span`, filled by whichever parser knows
// the offset and left nil by any that does not. It is excluded from `==` and `hash`
// everywhere it appears, so two documents differing only in whitespace stay equal.
//
// What this file checks is not that spans exist but that they point at the RIGHT BYTES.
// A span that is merely present renders a caret under the wrong thing, which is worse than
// no caret, so every case below asserts the underlined text.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayCore
import AssayYAML
import AssayXML

@Schema(keys: .snakeCase, coerceScalars: true, formats: .all)
struct Deploy {
    var name: String
    @Validate(.range(1...100)) var replicaCount: Int
    @Validate(.min(3)) var image: String
}

/// The bytes a caret would underline, or nil when the issue carries no span.
private func underlined(_ d: Diagnosis<Deploy>, _ source: String) -> String? {
    guard let span = d.issues.first?.location else { return nil }
    let bytes = Array(source.utf8)
    let lo = Int(span.lo), hi = min(bytes.count, lo + Int(span.len))
    guard lo < hi else { return nil }
    return String(decoding: Array(bytes[lo..<hi]), as: UTF8.self)
}

@Suite("YAML carets")
struct YAMLSpanTests {

    @Test("a rule violation underlines the value, and nothing else", arguments: [
        "name: api\nreplica_count: 0\nimage: web:1.4\n",
        // A trailing comment is not part of the value.
        "name: api\nreplica_count: 0   # why though\nimage: web:1.4\n",
        // Nor are blank lines or a comment on the following line.
        "name: api\nreplica_count: 0\n\n\nimage: web:1.4\n",
        "name: api\nreplica_count: 0\n# a note\nimage: web:1.4\n",
        // Nor the absence of a trailing newline.
        "name: api\nimage: web:1.4\nreplica_count: 0",
        // Flow style ends at the `,` rather than a newline.
        "{name: api, replica_count: 0, image: web:1.4}\n",
    ])
    func ruleViolationUnderlinesTheValue(_ yaml: String) {
        let d = Deploy.diagnose(yaml: yaml)
        #expect(!d.isValid)
        #expect(underlined(d, yaml) == "0", "for: \(yaml.debugDescription)")
    }

    @Test("a type mismatch underlines the whole bad token")
    func typeMismatch() {
        let yaml = "name: api\nreplica_count: not-a-number\nimage: web:1.4\n"
        let d = Deploy.diagnose(yaml: yaml)
        #expect(underlined(d, yaml) == "not-a-number")
    }

    /// The guard that makes a backward scan for the comment safe. A quoted scalar owns
    /// every byte between its quotes, `#` included.
    @Test("a hash inside a quoted scalar is content, not a comment")
    func hashInsideQuotes() throws {
        let yaml = "name: \"a # b\"\nreplica_count: 0\nimage: web:1.4\n"
        let d = Deploy.diagnose(yaml: yaml)
        #expect(underlined(d, yaml) == "0")

        let ok = try Deploy.parse(yaml: "name: \"a # b\"\nreplica_count: 5\nimage: web:1.4\n")
        #expect(ok.name == "a # b", "and the value itself survives intact")
    }

    /// `#` opens a comment only after whitespace, which is what keeps `a#b` one scalar.
    @Test("a hash with no leading space is part of a plain scalar")
    func hashWithoutSpace() throws {
        let v = try Deploy.parse(yaml: "name: a#b\nreplica_count: 5\nimage: web:1.4\n")
        #expect(v.name == "a#b")
    }

    @Test("the caret renders, and points at the right line and column")
    func rendering() {
        let yaml = "# a deployment\nname: api\nreplica_count: 0\nimage: web:1.4\n"
        let text = Deploy.diagnose(yaml: yaml).render(.plain)
        #expect(text.contains("<input>:3:16:"), "got:\n\(text)")
        #expect(text.contains("^"))
    }

    @Test("a missing field still has no span — there is nothing to point at")
    func missingHasNoSpan() {
        let d = Deploy.diagnose(yaml: "name: api\nimage: web:1.4\n")
        #expect(!d.isValid)
        #expect(d.issues.allSatisfy { $0.location == nil })
    }
}

@Suite("XML carets")
struct XMLSpanTests {

    @Test("element text is underlined, not the markup around it")
    func elementText() {
        let xml = "<deploy><name>api</name><replica_count>0</replica_count>"
            + "<image>web:1.4</image></deploy>"
        let d = Deploy.diagnose(xml: xml)
        #expect(underlined(d, xml) == "0")
    }

    @Test("a type mismatch underlines the whole text run")
    func typeMismatch() {
        let xml = "<deploy><name>api</name><replica_count>nope</replica_count>"
            + "<image>web:1.4</image></deploy>"
        let d = Deploy.diagnose(xml: xml)
        #expect(underlined(d, xml) == "nope")
    }

    @Test("text spanning lines keeps its own extent")
    func multiline() {
        let xml = """
        <deploy>
          <name>api</name>
          <replica_count>0</replica_count>
          <image>web:1.4</image>
        </deploy>
        """
        let d = Deploy.diagnose(xml: xml)
        #expect(underlined(d, xml) == "0")
    }
}

@Schema(coerceScalars: true, formats: [.xml])
struct Attributed {
    @XML(.attribute) @Validate(.min(3)) var env: String
    @XML(.attribute) @Validate(.range(1...9)) var tier: Int
}

@Suite("XML attribute carets")
struct XMLAttributeSpanTests {

    /// The attribute VALUE, inside the quotes — not `env="x"`, which would point partly at
    /// the name. The parser keeps both spans: the whole attribute for a duplicate-attribute
    /// report, the value alone for a schema issue.
    @Test("an attribute rule underlines the value inside the quotes")
    func attributeValue() {
        let xml = #"<a env="x" tier="5"/>"#
        let d = Attributed.diagnose(xml: xml)
        guard let span = d.issues.first?.location else {
            Issue.record("no span on an attribute issue"); return
        }
        let bytes = Array(xml.utf8)
        let text = String(decoding: Array(bytes[Int(span.lo)..<Int(span.lo) + Int(span.len)]),
                          as: UTF8.self)
        #expect(text == "x")
    }

    @Test("a numeric attribute underlines its digits")
    func numericAttribute() {
        let xml = #"<a env="prod" tier="99"/>"#
        let d = Attributed.diagnose(xml: xml)
        guard let span = d.issues.first?.location else {
            Issue.record("no span"); return
        }
        let bytes = Array(xml.utf8)
        let text = String(decoding: Array(bytes[Int(span.lo)..<Int(span.lo) + Int(span.len)]),
                          as: UTF8.self)
        #expect(text == "99")
    }
}

@Suite("A span is provenance, not value")
struct SpanEqualityTests {

    /// The property that makes it safe to hang spans on public types. `@Extras` hands
    /// `RawValue` to users as ordinary data, and two documents with the same content must
    /// compare equal however they were laid out.
    @Test("documents differing only in whitespace stay equal")
    func whitespaceDoesNotChangeIdentity() throws {
        let a = try YAML.parse("a: 1\nb: two\n")
        let b = try YAML.parse("a:   1\n\n# comment\nb: two   # trailing\n")
        #expect(a == b)
        #expect(RawValue(a) == RawValue(b))

        var hasher1 = Hasher(), hasher2 = Hasher()
        RawValue(a).hash(into: &hasher1)
        RawValue(b).hash(into: &hasher2)
        #expect(hasher1.finalize() == hasher2.finalize())
    }

    @Test("but the spans themselves do differ")
    func spansAreRecorded() throws {
        let a = try YAML.parse("a: 1\n")
        let b = try YAML.parse("a:      1\n")
        guard case .mapping(let ma) = RawValue(a)!, case .mapping(let mb) = RawValue(b)! else {
            Issue.record("expected mappings"); return
        }
        #expect(ma[0].span != nil)
        #expect(mb[0].span != nil)
        #expect(ma[0].span != mb[0].span, "different columns, different spans")
    }

    @Test("XML elements and attributes compare on content, not layout")
    func xmlEquality() throws {
        let a = try XML.parse(#"<a x="1"><b>2</b></a>"#)
        let b = try XML.parse("<a   x=\"1\" >\n  <b>2</b>\n</a>")
        #expect(a.root.attributes == b.root.attributes)
        #expect(a.root.name == b.root.name)
    }
}
