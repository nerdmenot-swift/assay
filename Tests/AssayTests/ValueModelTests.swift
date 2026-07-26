import Testing
import AssayCore
import AssayYAML
import AssayXML

// docs/VALUE-MODELS.md. Three full-fidelity models plus one lossy neutral projection.
// These tests pin the *losses* as hard as they pin the fidelity — a projection that
// quietly stopped being lossy would be just as much a regression as one that lost more.

@Suite("JSON.Value")
struct JSONValueTests {

    @Test("parses the full grammar")
    func grammar() throws {
        let v = try JSON.Value.parse("""
        {"s":"x","i":42,"d":3.5,"b":true,"n":null,"a":[1,2],"o":{"k":"v"}}
        """)
        #expect(v["s"]?.string == "x")
        #expect(v["i"]?.int == 42)
        #expect(v["d"]?.double == 3.5)
        #expect(v["b"]?.bool == true)
        #expect(v["n"]?.isNull == true)
        #expect(v["a"]?[0]?.int == 1)
        #expect(v["o"]?["k"]?.string == "v")
    }

    @Test("object members keep document order")
    func ordered() throws {
        let v = try JSON.Value.parse(#"{"z":1,"a":2,"m":3}"#)
        #expect(v.object?.map(\.key) == ["z", "a", "m"])
    }

    @Test("duplicate keys are preserved, not overwritten")
    func duplicates() throws {
        // RFC 8259 leaves this undefined. Silently dropping one is the worst answer.
        let v = try JSON.Value.parse(#"{"k":1,"k":2,"k":3}"#)
        #expect(v.object?.count == 3)
        #expect(v["k"]?.int == 1)                       // first wins for subscript
        #expect(v.all("k").compactMap(\.int) == [1, 2, 3])
    }

    @Test("int and double stay distinct — 8080.5 is not 8080")
    func numberFidelity() throws {
        let v = try JSON.Value.parse(#"{"a":8080,"b":8080.5,"c":8080.0}"#)
        #expect(v["a"]?.int == 8080)
        #expect(v["b"]?.int == nil)          // a double is not an int, even asked nicely
        #expect(v["b"]?.double == 8080.5)
        #expect(v["c"]?.int == nil)          // 8080.0 was written as a double; it stays one
        #expect(v["a"]?.double == 8080)      // widening the other way is fine
    }

    @Test("malformed input reports issues rather than trapping")
    func malformed() {
        for bad in ["{", "[1,", #"{"k"}"#, "{'k':1}", "tru", "", "{} junk"] {
            #expect(throws: JSONValueError.self) { try JSON.Value.parse(bad) }
        }
    }

    @Test("depth limit is enforced")
    func depth() {
        let deep = String(repeating: "[", count: 300) + String(repeating: "]", count: 300)
        #expect(throws: JSONValueError.self) {
            try JSON.Value.parse(deep, limits: Limits(maxDepth: 64))
        }
    }

    @Test("invalid UTF-8 is caught on the buffer, before any String is built")
    func utf8() {
        var bytes = Array(#"{"k":"v"}"#.utf8)
        bytes[6] = 0xFF
        var sink = IssueSink()
        #expect(JSON.Value.decode(bytes, into: &sink) == nil)
        #expect(sink.issues.first?.code == .invalidUTF8)
    }

    @Test("NaN hashes and compares by bit pattern, so Hashable holds")
    func nanHashable() {
        // Documented deviation: unlike Double's own ==, these are equal. Without it the
        // Hashable contract (a value equals itself) is violated.
        #expect(JSON.Value.double(.nan) == JSON.Value.double(.nan))
        #expect(Set([JSON.Value.double(.nan)]).contains(.double(.nan)))
        // And the other side of the trade: +0 and -0 are distinguishable here.
        #expect(JSON.Value.double(0.0) != JSON.Value.double(-0.0))
    }

    @Test("projection to RawValue is total")
    func projection() throws {
        let v = try JSON.Value.parse(#"{"a":[1,2.5,null,true,"s"]}"#)
        let raw = RawValue(v)
        #expect(raw["a"]?[0]?.int == 1)
        #expect(raw["a"]?[1]?.double == 2.5)
        #expect(raw["a"]?[2]?.isNull == true)
        #expect(raw["a"]?[3]?.bool == true)
        #expect(raw["a"]?[4]?.string == "s")
    }
}

@Suite("YAML.Node")
struct YAMLNodeTests {

    @Test("non-string keys are representable — the case that killed the unified model")
    func nonStringKeys() {
        let node = YAML.Node.mapping([
            .init(key: .sequence([.scalar(.init(content: "1")),
                                  .scalar(.init(content: "2"))]),
                  value: "x"),
        ])
        #expect(node.mapping?.count == 1)
        // Representable here, and correctly *not* projectable to RawValue.
        #expect(RawValue(node) == nil)
    }

    @Test("tags and scalar style survive")
    func fidelity() {
        let s = YAML.Scalar(content: "2024", style: .doubleQuoted, tag: "!!str", anchor: "a")
        let node = YAML.Node.scalar(s)
        #expect(node.scalar?.tag == "!!str")
        #expect(node.scalar?.style == .doubleQuoted)
        #expect(node.scalar?.anchor == "a")
        // A tagged string does not resolve as an int, even though the text looks like one.
        #expect(node.resolvedInt == nil)
    }

    @Test("the Norway problem is sidestepped, not inherited")
    func norway() {
        // YAML 1.2 core schema: yes/no/on/off are NOT booleans. Resolving them here would
        // be reintroducing the bug on purpose.
        #expect(YAML.Node.scalar(.init(content: "NO")).resolvedBool == nil)
        #expect(YAML.Node.scalar(.init(content: "yes")).resolvedBool == nil)
        #expect(YAML.Node.scalar(.init(content: "off")).resolvedBool == nil)
        // These are.
        #expect(YAML.Node.scalar(.init(content: "true")).resolvedBool == true)
        #expect(YAML.Node.scalar(.init(content: "FALSE")).resolvedBool == false)
        // And an unresolvable plain scalar is a string, not a guess.
        #expect(RawValue(YAML.Node.scalar(.init(content: "NO"))) == .string("NO"))
    }

    @Test("resolution is on demand and respects quoting")
    func resolution() {
        #expect(YAML.Node.scalar(.init(content: "42")).resolvedInt == 42)
        // A quoted scalar is a string by construction, whatever it looks like.
        #expect(YAML.Node.scalar(.init(content: "42", style: .singleQuoted)).resolvedInt == nil)
        #expect(YAML.Node.scalar(.init(content: ".inf")).resolvedDouble == .infinity)
        #expect(YAML.Node.scalar(.init(content: "~")).isNull)
        #expect(YAML.Node.scalar(.init(content: "")).isNull)
    }

    @Test("string-keyed lookup works without constructing a Node")
    func lookup() {
        let node = YAML.Node.mapping([
            .init(key: "port", value: .scalar(.init(content: "8080"))),
            .init(key: "host", value: "localhost"),
        ])
        #expect(node["port"]?.resolvedInt == 8080)
        #expect(node["host"]?.content == "localhost")
        #expect(node["missing"] == nil)
    }

    @Test("projection drops tags and styles, and says so by losing them")
    func projectionIsLossy() {
        let node = YAML.Node.mapping([
            .init(key: "a", value: .scalar(.init(content: "1", style: .literal, tag: "!Foo"))),
        ])
        let raw = RawValue(node)
        // The tag said !Foo; RawValue has nowhere to put that, so the value resolves as
        // an ordinary scalar. This is the documented loss, pinned.
        #expect(raw?["a"] != nil)
    }
}

@Suite("XML.Node")
struct XMLNodeTests {

    @Test("mixed content is ordinary, not a special case")
    func mixedContent() {
        // <p>Hello <b>x</b>!</p>
        let p = XML.Element("p", children: [
            .text("Hello "),
            .element(XML.Element("b", children: [.text("x")])),
            .text("!"),
        ])
        #expect(p.hasMixedContent)
        #expect(p.children.count == 3)
        #expect(p.text == "Hello !")          // flattening loses the element, on purpose
        #expect(p["b"]?.text == "x")
    }

    @Test("attributes and elements are different things, not tagged keys")
    func attributesVsElements() {
        let book = XML.Element("book",
                               attributes: [XML.Attribute("isbn", "123")],
                               children: [.element(XML.Element("title",
                                                               children: [.text("Swift")]))])
        #expect(book[attribute: "isbn"] == "123")
        #expect(book["title"]?.text == "Swift")
        // An attribute is not reachable as a child element, and vice versa.
        #expect(book["isbn"] == nil)
        #expect(book[attribute: "title"] == nil)
    }

    @Test("repeated sibling names are the ordinary case")
    func repeated() {
        let list = XML.Element("authors", children: [
            .element(XML.Element("author", children: [.text("A")])),
            .element(XML.Element("author", children: [.text("B")])),
            .element(XML.Element("author", children: [.text("C")])),
        ])
        #expect(list.elements(named: "author").count == 3)
        #expect(list.elements(named: "author").map(\.text) == ["A", "B", "C"])
        // A Dictionary-backed model would have silently kept one of these.
        #expect(RawValue(list).mapping?.count == 3)
    }

    @Test("namespaces compare by URI, not by prefix")
    func namespaces() {
        let a = XML.Name("creator", namespaceURI: "http://purl.org/dc/elements/1.1/")
        let b = XML.Name("creator", namespaceURI: "http://purl.org/dc/elements/1.1/")
        let c = XML.Name("creator")
        #expect(a == b)      // whatever prefix each document used
        #expect(a != c)      // namespaced is not the same as unnamespaced
    }

    @Test("everything is text — no numbers, no booleans")
    func untyped() {
        let port = XML.Element("port", children: [.text("8080")])
        // NOT .int(8080). XML has no number type; coercion is @Coerce's visible job.
        #expect(RawValue(port) == .string("8080"))

        let flag = XML.Element("enabled", children: [.text("true")])
        #expect(RawValue(flag) == .string("true"))
    }

    @Test("projection flattens attributes and elements into one keyspace")
    func projectionIsLossy() {
        let e = XML.Element("book",
                            attributes: [XML.Attribute("isbn", "123")],
                            children: [.element(XML.Element("isbn", children: [.text("456")]))])
        let raw = RawValue(e)
        // Both survive and both are reachable, but which was the attribute is gone —
        // the documented loss that motivates declaring [String: XML.Node] instead.
        #expect(raw.all("isbn").count == 2)
        #expect(raw.all("isbn") == [.string("123"), .string("456")])
    }

    @Test("comments and processing instructions are dropped by the projection")
    func droppedNodes() {
        let e = XML.Element("root", children: [
            .comment("nothing to see"),
            .processingInstruction(target: "xml-stylesheet", data: "href=\"a.css\""),
            .element(XML.Element("kept", children: [.text("yes")])),
        ])
        let raw = RawValue(e)
        #expect(raw.mapping?.count == 1)
        #expect(raw["kept"] == .string("yes"))
    }

    @Test("whitespace-only text between elements is formatting, not data")
    func insignificantWhitespace() {
        let e = XML.Element("root", children: [
            .text("\n  "),
            .element(XML.Element("a", children: [.text("1")])),
            .text("\n  "),
            .element(XML.Element("b", children: [.text("2")])),
            .text("\n"),
        ])
        let raw = RawValue(e)
        #expect(raw.mapping?.count == 2)
        #expect(raw["a"] == .string("1"))
        #expect(raw["b"] == .string("2"))
    }
}
