// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// XML encoding, and the round-trip law for it. docs/ENCODING.md.
//
// The two defaults under test were settled by surveying the field, not by taste:
// unannotated fields are ELEMENTS (Jackson, Go, .NET and pydantic-xml all agree, none
// defaults to an attribute), and unannotated arrays are UNWRAPPED REPEATED SIBLINGS
// (Go's encoding/xml and serde-xml-rs — the two whose XML support was designed rather
// than retrofitted onto a JSON mapper).
//
// `@XML(.wrapped)` exists for the one thing unwrapped cannot express: absent versus
// empty. Its test is the one that would fail if the default were changed to wrapped.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayXML

@Schema(coerceScalars: true, formats: .all, encodes: true)
struct XDoc: Equatable {
    @XML(.attribute) var id: Int
    var name: String
    var ratio: Double
    var active: Bool
    var tags: [String] = []
    @XML(.wrapped) var wrapped: [String] = []
    var nested: XLeaf
    var items: [XLeaf] = []
}

@Schema(coerceScalars: true, formats: .all, encodes: true)
struct XLeaf: Equatable {
    @XML(.attribute) var key: String
    var value: Int
}

@Schema(coerceScalars: true, formats: .all, encodes: true)
struct XText: Equatable {
    @XML(.attribute) var lang: String
    @XML(.text) var body: String
}

@Suite("XML encoding")
struct XMLEncodingTests {

    @Test("round-trip: parse -> encode -> parse is identity")
    func roundTrip() throws {
        let xml = """
        <XDoc id="7"><name>ada</name><ratio>1.5</ratio><active>true</active>\
        <tags>a</tags><tags>b</tags><wrapped><item>w1</item></wrapped>\
        <nested key="k"><value>1</value></nested>\
        <items key="i1"><value>10</value></items><items key="i2"><value>20</value></items></XDoc>
        """
        let original = try XDoc.parse(xml: xml)
        let encoded = try original.encode(xml: nil)
        let again = try XDoc.parse(xml: encoded)
        #expect(again == original,
                "round-trip must be identity; encoded:\n\(String(decoding: encoded, as: UTF8.self))")
    }

    @Test("Decision A: an unannotated field is an element, an annotated one an attribute")
    func placement() throws {
        let v = XDoc(id: 7, name: "ada", ratio: 0, active: false, tags: [], wrapped: [],
                     nested: XLeaf(key: "k", value: 1), items: [])
        let text = try v.encodedXML()
        #expect(text.contains(#"id="7""#), "annotated field must be an attribute:\n\(text)")
        #expect(text.contains("<name>ada</name>"), "unannotated must be an element:\n\(text)")
        #expect(!text.contains(#"name="ada""#))
    }

    @Test("Decision B: arrays are unwrapped repeated siblings by default")
    func unwrappedArrays() throws {
        let v = XDoc(id: 1, name: "n", ratio: 0, active: false, tags: ["a", "b"],
                     wrapped: [], nested: XLeaf(key: "k", value: 0), items: [])
        let text = try v.encodedXML()
        #expect(text.contains("<tags>a</tags><tags>b</tags>"), "got:\n\(text)")
        #expect(try XDoc.parse(xml: v.encode(xml: nil)) == v)
    }

    /// The case `.wrapped` exists for, and the one that would fail if unwrapped were the
    /// only option: an empty array must not come back as an absent one.
    @Test("@XML(.wrapped) keeps empty distinguishable, which unwrapped cannot")
    func wrappedKeepsEmpty() throws {
        let v = XDoc(id: 1, name: "n", ratio: 0, active: false, tags: [], wrapped: [],
                     nested: XLeaf(key: "k", value: 0), items: [])
        let text = try v.encodedXML()
        // The wrapper is written even when empty; the unwrapped array vanishes entirely.
        #expect(text.contains("<wrapped/>") || text.contains("<wrapped></wrapped>"),
                "an empty wrapped array must still write its wrapper:\n\(text)")
        #expect(!text.contains("<tags"), "an empty unwrapped array writes nothing")
        #expect(try XDoc.parse(xml: v.encode(xml: nil)) == v)
    }

    @Test("nested schemas and arrays of them round-trip")
    func nesting() throws {
        let v = XDoc(id: 1, name: "n", ratio: 2.5, active: true, tags: ["x"],
                     wrapped: ["w"], nested: XLeaf(key: "nk", value: 9),
                     items: [XLeaf(key: "a", value: 1), XLeaf(key: "b", value: 2)])
        let again = try XDoc.parse(xml: v.encode(xml: nil))
        #expect(again == v)
    }

    @Test("@XML(.text) writes character data alongside attributes")
    func textPlacement() throws {
        let v = XText(lang: "en", body: "hello world")
        let text = try v.encodedXML()
        #expect(text.contains(#"<XText lang="en">hello world</XText>"#), "got:\n\(text)")
        #expect(try XText.parse(xml: v.encode(xml: nil)) == v)
    }

    @Test("markup in content and attributes is escaped, and survives")
    func escaping() throws {
        let nasty = "a<b>&c\"d'e\nf\tg"
        let v = XText(lang: nasty, body: nasty)
        let again = try XText.parse(xml: v.encode(xml: nil))
        #expect(again.body == nasty, "text did not survive")
        // Attribute-value normalisation would eat a raw tab or newline, so they must be
        // written as character references.
        #expect(again.lang == nasty, "attribute did not survive")
    }

    @Test("the root element name defaults to the type name and can be overridden")
    func rootName() throws {
        let v = XText(lang: "en", body: "x")
        #expect(try v.encodedXML().contains("<XText "))
        #expect(try v.encodedXML(root: "message").contains("<message "))
        #expect(try XText.parse(xml: v.encode(xml: "message")) == v)
    }

    @Test("non-finite doubles are reported — XML has no numeric type to hold them")
    func nonFinite() {
        let v = XDoc(id: 1, name: "n", ratio: .nan, active: false, tags: [], wrapped: [],
                     nested: XLeaf(key: "k", value: 0), items: [])
        let d = v.diagnoseEncode(xml: nil)
        #expect(!d.isValid)
        #expect(d.issues.contains { $0.code == .unrepresentableValue })
    }

    @Test("encoding is stable — twice gives identical bytes")
    func stable() throws {
        let v = XDoc(id: 1, name: "n", ratio: 1, active: true, tags: ["b", "a"],
                     wrapped: ["z"], nested: XLeaf(key: "k", value: 1), items: [])
        #expect(try v.encode(xml: nil) == v.encode(xml: nil))
    }
}

@Suite("XML placement diagnostics")
struct XMLPlacementDiagnosticTests {

    @Test("@XML(.attribute) on an array is refused at expansion")
    func attributeOnArray() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema(formats: .all, encodes: true) struct S { @XML(.attribute) var tags: [String] }
        """)
        #expect(diags.contains { $0.contains("scalar fields") && $0.contains("'tags'") })
    }

    @Test("@XML(.wrapped) on a scalar is refused at expansion")
    func wrappedOnScalar() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema(formats: .all, encodes: true) struct S { @XML(.wrapped) var name: String }
        """)
        #expect(diags.contains { $0.contains("array fields") && $0.contains("'name'") })
    }
}
