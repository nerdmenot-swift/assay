import Testing
import AssayCore
import AssayYAML
import AssayXML

@Suite("XML parser")
struct XMLParserTests {

    @Test("elements, attributes, text")
    func basics() throws {
        let doc = try XML.parse("""
        <book isbn="123" lang="en"><title>Swift</title><year>2026</year></book>
        """)
        #expect(doc.root.name.local == "book")
        #expect(doc.root[attribute: "isbn"] == "123")
        #expect(doc.root["title"]?.text == "Swift")
        #expect(doc.root["year"]?.text == "2026")
    }

    @Test("repeated siblings are preserved in order")
    func repeated() throws {
        let doc = try XML.parse("<r><a>1</a><a>2</a><a>3</a></r>")
        #expect(doc.root.elements(named: "a").map(\.text) == ["1", "2", "3"])
    }

    @Test("mixed content keeps interleaving")
    func mixed() throws {
        let doc = try XML.parse("<p>Hello <b>x</b>!</p>")
        #expect(doc.root.hasMixedContent)
        #expect(doc.root.children.count == 3)
        #expect(doc.root["b"]?.text == "x")
    }

    @Test("self-closing and empty elements")
    func selfClosing() throws {
        let doc = try XML.parse("<r><a/><b></b><c d='1'/></r>")
        #expect(doc.root.childElements.count == 3)
        #expect(doc.root["c"]?[attribute: "d"] == "1")
    }

    @Test("predefined and numeric entities resolve")
    func entities() throws {
        let doc = try XML.parse("<r>&lt;&amp;&gt;&quot;&apos;&#65;&#x42;</r>")
        #expect(doc.root.text == "<&>\"'AB")
    }

    @Test("entities resolve inside attributes too")
    func attributeEntities() throws {
        let doc = try XML.parse(#"<r a="x &amp; y"/>"#)
        #expect(doc.root[attribute: "a"] == "x & y")
    }

    @Test("CDATA is preserved verbatim and not entity-decoded")
    func cdata() throws {
        let doc = try XML.parse("<r><![CDATA[a < b && c > d]]></r>")
        #expect(doc.root.text == "a < b && c > d")
    }

    @Test("comments and processing instructions are retained as nodes")
    func commentsAndPIs() throws {
        let doc = try XML.parse("<?xml version='1.0'?><!--hi--><r><?go now?></r>")
        #expect(doc.prolog.contains { if case .comment(let c) = $0 { return c == "hi" }; return false })
        #expect(doc.root.children.contains {
            if case .processingInstruction(let t, _) = $0 { return t == "go" }
            return false
        })
    }

    @Test("namespaces resolve to URIs and prefixes are discarded")
    func namespaces() throws {
        let doc = try XML.parse("""
        <r xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator>Ada</dc:creator></r>
        """)
        let creator = doc.root.childElements[0]
        #expect(creator.name.local == "creator")
        #expect(creator.name.namespaceURI == "http://purl.org/dc/elements/1.1/")

        // Same URI, different prefix — must compare equal.
        let other = try XML.parse("""
        <r xmlns:x="http://purl.org/dc/elements/1.1/"><x:creator>Ada</x:creator></r>
        """)
        #expect(other.root.childElements[0].name == creator.name)
    }

    @Test("default namespace applies to elements but NOT to unprefixed attributes")
    func defaultNamespace() throws {
        let doc = try XML.parse(#"<r xmlns="urn:x" a="1"><c/></r>"#)
        #expect(doc.root.name.namespaceURI == "urn:x")
        #expect(doc.root["c"]?.name.namespaceURI == "urn:x")
        // Per the Namespaces spec, an unprefixed attribute is in NO namespace.
        #expect(doc.root.attributes[0].name.namespaceURI == nil)
    }

    @Test("mismatched and unclosed tags are errors with the tag named")
    func wellFormedness() {
        #expect(throws: XMLParseError.self) { try XML.parse("<a></b>") }
        #expect(throws: XMLParseError.self) { try XML.parse("<a><b></a>") }
        #expect(throws: XMLParseError.self) { try XML.parse("<a>") }
        #expect(throws: XMLParseError.self) { try XML.parse("no root") }
        #expect(throws: XMLParseError.self) { try XML.parse("<a/><b/>") }
    }

    @Test("SECURITY: external entities are never fetched, only warned about")
    func xxe() {
        // The classic XXE payload. It must not resolve, and must not reach the filesystem.
        let payload = """
        <!DOCTYPE r [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><r>&xxe;</r>
        """
        var sink = IssueSink()
        let doc = XML.decode(Array(payload.utf8), into: &sink)
        // The entity is undeclared as far as expansion is concerned, so it errors rather
        // than silently passing raw text through.
        #expect(doc == nil || !sink.isValid)
        #expect(sink.warnings.contains { $0.code == .custom("xml_external_entity_ignored") }
                || sink.issues.contains { $0.code == .custom("xml_undeclared_entity") })
    }

    @Test("SECURITY: billion laughs is capped")
    func billionLaughs() {
        let payload = """
        <!DOCTYPE lolz [
         <!ENTITY lol "lol">
         <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
         <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
        ]><lolz>&lol3;&lol3;&lol3;&lol3;&lol3;</lolz>
        """
        var sink = IssueSink()
        // Must terminate — the assertion is that this returns at all.
        _ = XML.decode(Array(payload.utf8), into: &sink,
                       limits: Limits(maxIssues: 10, maxDepth: 64, maxBytes: 4096))
        #expect(true)
    }

    @Test("internal entities declared in the subset DO resolve")
    func internalEntities() throws {
        let doc = try XML.parse("""
        <!DOCTYPE r [<!ENTITY name "Assay">]><r>&name;</r>
        """)
        #expect(doc.root.text == "Assay")
    }

    @Test("depth limit is enforced")
    func depth() {
        let deep = String(repeating: "<a>", count: 300) + String(repeating: "</a>", count: 300)
        #expect(throws: XMLParseError.self) {
            try XML.parse(deep, limits: Limits(maxIssues: 10, maxDepth: 64, maxBytes: 1 << 20))
        }
    }

    @Test("projection to RawValue still works on parsed documents")
    func projection() throws {
        let doc = try XML.parse(#"<book isbn="1"><title>Swift</title></book>"#)
        let raw = RawValue(doc)
        #expect(raw["isbn"] == .string("1"))
        #expect(raw["title"] == .string("Swift"))
    }
}

@Suite("YAML parser")
struct YAMLParserTests {

    @Test("block mapping and scalars")
    func blockMapping() throws {
        let n = try YAML.parse("""
        name: api
        port: 8080
        debug: true
        """)
        #expect(n["name"]?.content == "api")
        #expect(n["port"]?.resolvedInt == 8080)
        #expect(n["debug"]?.resolvedBool == true)
    }

    @Test("block sequences")
    func blockSequence() throws {
        let n = try YAML.parse("""
        - a
        - b
        - c
        """)
        #expect(n.sequence?.count == 3)
        #expect(n[0]?.content == "a")
        #expect(n[2]?.content == "c")
    }

    @Test("nested block structures")
    func nested() throws {
        let n = try YAML.parse("""
        database:
          host: localhost
          ports:
            - 5432
            - 5433
        """)
        #expect(n["database"]?["host"]?.content == "localhost")
        #expect(n["database"]?["ports"]?.sequence?.count == 2)
        #expect(n["database"]?["ports"]?[1]?.resolvedInt == 5433)
    }

    @Test("flow collections")
    func flow() throws {
        let n = try YAML.parse("a: [1, 2, 3]\nb: {x: 1, y: 2}")
        #expect(n["a"]?.sequence?.count == 3)
        #expect(n["b"]?["y"]?.resolvedInt == 2)
    }

    @Test("quoted scalars, with escapes")
    func quoted() throws {
        let n = try YAML.parse("""
        a: "line\\nbreak"
        b: 'it''s'
        c: "tab\\there"
        d: "\\u0041"
        """)
        #expect(n["a"]?.content == "line\nbreak")
        #expect(n["b"]?.content == "it's")
        #expect(n["c"]?.content == "tab\there")
        #expect(n["d"]?.content == "A")
    }

    @Test("a quoted scalar is a string whatever it looks like")
    func quotedIsString() throws {
        let n = try YAML.parse("a: \"42\"\nb: 42")
        #expect(n["a"]?.scalar?.style == .doubleQuoted)
        #expect(n["a"]?.resolvedInt == nil)        // quoted -> not a number
        #expect(n["b"]?.resolvedInt == 42)
    }

    @Test("literal and folded block scalars")
    func blockScalars() throws {
        let n = try YAML.parse("""
        lit: |
          line one
          line two
        fold: >
          line one
          line two
        """)
        #expect(n["lit"]?.content == "line one\nline two\n")
        #expect(n["lit"]?.scalar?.style == .literal)
        #expect(n["fold"]?.content == "line one line two\n")
        #expect(n["fold"]?.scalar?.style == .folded)
    }

    @Test("strip chomping removes the trailing newline")
    func chomping() throws {
        let n = try YAML.parse("""
        a: |-
          text
        b: |
          text
        """)
        #expect(n["a"]?.content == "text")
        #expect(n["b"]?.content == "text\n")
    }

    @Test("comments are ignored, but # inside a scalar is not a comment")
    func comments() throws {
        let n = try YAML.parse("""
        # leading comment
        a: 1   # trailing comment
        b: has#hash
        """)
        #expect(n["a"]?.resolvedInt == 1)
        #expect(n["b"]?.content == "has#hash")
    }

    @Test("anchors and aliases")
    func anchors() throws {
        let n = try YAML.parse("""
        base: &b
          x: 1
          y: 2
        copy: *b
        """)
        #expect(n["copy"]?["x"]?.resolvedInt == 1)
        #expect(n["copy"]?["y"]?.resolvedInt == 2)
    }

    @Test("merge keys are applied, and explicit keys win")
    func mergeKeys() throws {
        let n = try YAML.parse("""
        base: &b
          x: 1
          y: 2
        derived:
          <<: *b
          y: 99
        """)
        #expect(n["derived"]?["x"]?.resolvedInt == 1)
        #expect(n["derived"]?["y"]?.resolvedInt == 99)   // explicit beats merged
        // The literal "<<" key must not survive into the tree.
        #expect(n["derived"]?["<<"] == nil)
    }

    @Test("tags are preserved rather than resolved away")
    func tags() throws {
        let n = try YAML.parse("a: !!str 42")
        #expect(n["a"]?.scalar?.tag == "!!str")
        #expect(n["a"]?.resolvedInt == nil)     // tagged as a string, so not an int
    }

    @Test("multiple documents")
    func multiDoc() throws {
        let docs = try YAML.parseAll("""
        ---
        a: 1
        ---
        a: 2
        ...
        """)
        #expect(docs.count == 2)
        #expect(docs[0]["a"]?.resolvedInt == 1)
        #expect(docs[1]["a"]?.resolvedInt == 2)
    }

    @Test("non-string keys survive, which JSON-shaped models cannot represent")
    func nonStringKeys() throws {
        let n = try YAML.parse("? [1, 2]\n: value")
        guard case .mapping(let pairs) = n else { Issue.record("not a mapping"); return }
        #expect(pairs.count == 1)
        #expect(pairs[0].key.sequence?.count == 2)
        #expect(pairs[0].value.content == "value")
        // And correctly not projectable to the String-keyed RawValue.
        #expect(RawValue(n) == nil)
    }

    @Test("the Norway problem does not occur, because nothing is resolved at parse time")
    func norway() throws {
        let n = try YAML.parse("country: NO\nenabled: yes")
        #expect(n["country"]?.content == "NO")
        #expect(n["country"]?.resolvedBool == nil)     // NOT false
        #expect(n["enabled"]?.resolvedBool == nil)     // NOT true — that is YAML 1.1
        #expect(RawValue(n)?["country"] == .string("NO"))
    }

    @Test("null spellings")
    func nulls() throws {
        let n = try YAML.parse("a: null\nb: ~\nc:\n")
        #expect(n["a"]?.isNull == true)
        #expect(n["b"]?.isNull == true)
        #expect(n["c"]?.isNull == true)
    }

    @Test("SECURITY: alias expansion is bounded")
    func aliasBomb() {
        let payload = """
        a: &a [x, x, x, x, x, x, x, x, x, x]
        b: &b [*a, *a, *a, *a, *a, *a, *a, *a, *a, *a]
        c: &c [*b, *b, *b, *b, *b, *b, *b, *b, *b, *b]
        d: [*c, *c, *c, *c, *c, *c, *c, *c, *c, *c]
        """
        var sink = IssueSink()
        // Must terminate.
        _ = YAML.decodeAll(Array(payload.utf8), into: &sink,
                           limits: Limits(maxIssues: 10, maxDepth: 64, maxBytes: 4096))
        #expect(true)
    }

    @Test("projection to RawValue works on parsed documents")
    func projection() throws {
        let n = try YAML.parse("""
        name: api
        port: 8080
        tags: [a, b]
        """)
        let raw = RawValue(n)
        #expect(raw?["name"] == .string("api"))
        #expect(raw?["port"] == .int(8080))
        #expect(raw?["tags"] == .sequence([.string("a"), .string("b")]))
    }

    @Test("a realistic config file")
    func realistic() throws {
        let n = try YAML.parse("""
        # app config
        service_name: api
        port: 8080
        workers: 4
        database:
          url: "postgres://localhost/app"
          pool_size: 10
          ssl_required: true
        features:
          - metrics
          - tracing
        log_level: info
        """)
        #expect(n["service_name"]?.content == "api")
        #expect(n["port"]?.resolvedInt == 8080)
        #expect(n["database"]?["url"]?.content == "postgres://localhost/app")
        #expect(n["database"]?["pool_size"]?.resolvedInt == 10)
        #expect(n["features"]?.sequence?.count == 2)
        #expect(n["features"]?[0]?.content == "metrics")
    }
}

@Suite("Fuzz regressions")
struct FuzzRegressionTests {

    /// Found by Benchmarks/DiffFuzz: a plain flow scalar terminates on `}` without
    /// consuming it, so `[}]` produced an empty scalar, advanced nothing, and looped
    /// forever appending — a hang that ended in the OOM killer. Every one of these must
    /// terminate with an issue, not a value and not a wait.
    @Test("flow collections terminate on a stray closer", arguments: [
        "[}]", "[1,2}3]", "{\"a\":[1,2}3]}", "[1}2]", "[1,2}]", "{a: 1]}", "[[}]]",
    ])
    func flowCollectionsTerminate(_ input: String) {
        var sink = IssueSink()
        let docs = YAML.decodeAll(Array(input.utf8), into: &sink, limits: .default)
        #expect(sink.issues.isEmpty == false)
        _ = docs
    }

    @Test("valid flow collections still parse")
    func validFlowStillWorks() throws {
        var sink = IssueSink()
        let docs = YAML.decodeAll(Array("[1, 2, {a: b, c: [3]}]".utf8),
                                  into: &sink, limits: .default)
        #expect(sink.issues.isEmpty)
        #expect(docs.count == 1)
        guard case .sequence(let items) = docs[0] else {
            Issue.record("expected a sequence"); return
        }
        #expect(items.count == 3)
    }
}
