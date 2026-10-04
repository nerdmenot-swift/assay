// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Foundation
import Assay
import AssayCore
import AssayFoundation
import AssayPlist
import AssayTOML
import AssayXML

//===----------------------------------------------------------------------===//
// TOML, XML and property lists: each refusal by the smallest document that causes it.
//
// TOML's refusals are covered in CI by the official toml-test suite, 501 invalid documents —
// through `DiffFuzz`, which is a separate package, a release build, and Darwin-pinned. So
// `swift test` on Linux or Windows reached the common ones and none of these. The binary
// plist arms are the ones a fuzzer finds least often: each needs a specific marker byte or
// a trailer field off by a specific amount, and each guards a read from attacker-chosen
// offsets.
//
// Every expected code and offset below was printed by the parser first and read against
// the arm it was written to reach.
//===----------------------------------------------------------------------===//

// MARK: - TOML

@Suite("TOML: refusals by code and offset")
struct TOMLRefusalTableTests {

    @Test(
        "each malformed document is refused under its own code",
        arguments: [
            ("a = \n", IssueCode.tomlExpectedValue, 4),
            ("a = [1, 2\n", .tomlUnterminatedArray, 10),
            ("a = \"abc\n", .tomlUnterminatedString, 8),
            ("a = \"\"\"abc", .tomlUnterminatedString, 10),
            ("a = '''abc", .tomlUnterminatedString, 10),
            ("a = \"\\q\"\n", .tomlBadEscape, 5),
            ("a = \"\"\"x\"\"\" y\n", .tomlExpectedNewline, 12),
            ("a = \"\"\"\u{01}\"\"\"\n", .tomlControlCharacter, 7),
            ("a = 1__0\n", .tomlBadNumber, 4),
            ("a = +\n", .tomlBadNumber, 4),
            ("a = 0x1G\n", .tomlBadNumber, 4),
            ("a = 99999999999999999999\n", .numberOverflow, 4),
            ("a = 2024-13-01\n", .tomlBadDateTime, 4),
            ("a = 2024-01-01T25:00:00\n", .tomlBadDateTime, 4),
            ("a = 2024-01-01T00:00:00+25:00\n", .tomlBadDateTime, 4),
            ("a = 1979-05-27T07:32\n", .tomlBadDateTime, 4),
            ("a = 2024-01-01 x\n", .tomlExpectedNewline, 15),
            ("= 1\n", .tomlExpectedKey, 0),
            ("a. = 1\n", .tomlExpectedKey, 3),
            // A scalar cannot be extended into a table, by a dotted key or by a header.
            ("a = 1\na.b = 2\n", .tomlNotATable, 6),
            ("a = 1\n[a.b]\n", .tomlNotATable, 7)
        ])
    func refused(doc: String, code: IssueCode, at: Int) {
        var sink = IssueSink(limits: .default)
        #expect(TOML.decode(Array(doc.utf8), into: &sink) == nil, "\(doc)")
        #expect(sink.issues.map(\.code) == [code], "\(doc)")
        #expect(sink.issues.first?.location.map { Int($0.lo) } == at, "\(doc)")
    }

    /// The same refusals reached by RUNNING OUT OF INPUT rather than by a wrong byte. Each
    /// is a separate arm — "the cursor is nil" beside "the cursor is not what was wanted" —
    /// and a table that ends every document with a newline reaches only the second kind.
    @Test(
        "a document that simply stops is refused under the same codes",
        arguments: [
            ("a = ", IssueCode.tomlExpectedValue),
            ("a = [1,", .tomlUnterminatedArray),
            ("a = \"x\\", .tomlUnterminatedString),
            ("a = 'x\n", .tomlUnterminatedString),
            ("a.", .tomlExpectedKey),
            // An escape that is not one: backslash-space on one line, and in a multi-line
            // string where the backslash is not the last thing on its line.
            ("a = \"x\\ y\"\n", .tomlBadEscape),
            ("a = \"\"\"x\\ y\"\"\"\n", .tomlBadEscape),
            ("a = \'\'\'x\'\'\'\'\'\'\n", .tomlExpectedNewline),
            ("a = \'\'\'x\ry\'\'\'\n", .tomlControlCharacter),
            ("a = 1e999\n", .numberOverflow),
            ("a = 2024-1x-01\n", .tomlBadDateTime),
            ("a = 2024-01-01T00:00:00+0x:00\n", .tomlBadDateTime),
            ("\'\'\' k \'\'\' = 1\n", .tomlExpectedKey),
            ("\"\"\" k \"\"\" = 1\n", .tomlExpectedKey),
            ("a = [1]\n[a.b]\n", .tomlNotATable)
        ])
    func endOfInput(doc: String, code: IssueCode) {
        var sink = IssueSink(limits: .default)
        #expect(TOML.decode(Array(doc.utf8), into: &sink) == nil, "\(doc)")
        #expect(sink.issues.first?.code == code, "\(doc): \(sink.issues.map(\.code))")
    }

    @Test("an underscore between digits is a separator; `false` is a boolean")
    func accepted() throws {
        let doc = try TOML.parse("a = 1_000\nb = false\nc = 1e+2\n")
        #expect(doc["a"] == .int(1000))
        #expect(doc["b"] == .bool(false))
        #expect(doc["c"] == .double(100))
    }

    @Test("the document-level limits: maxBytes and invalid UTF-8")
    func limits() {
        var small = Limits.default
        small.maxBytes = 4
        var sink = IssueSink(limits: small)
        #expect(TOML.decode(Array("a = 12345\n".utf8), into: &sink, limits: small) == nil)
        #expect(sink.issues.map(\.code) == [.tooManyBytes])

        var sink2 = IssueSink(limits: .default)
        #expect(TOML.decode(Array("a = \"".utf8) + [0xFF, 0x22, 0x0A], into: &sink2) == nil)
        #expect(sink2.issues.map(\.code) == [.invalidUTF8])
        #expect(sink2.issues.first?.params["offset"] == .int(5))
    }

    @Test("members compare and hash by key and value, not by where they were written")
    func members() throws {
        let a = try TOML.parse("k = 1\n"), b = try TOML.parse("\n\n   k = 1\n")
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
    }
}

@Suite("TOML: what the writer cannot spell")
struct TOMLWriterEdgeTests {

    private func encode(_ v: RawValue) -> (text: String, issues: [AssayCore.Issue]) {
        var sink = IssueSink(limits: .default)
        let text = TOML.encode(v, into: &sink).text()
        return (text, sink.issues)
    }

    @Test("a null inside an array is reported at its index; one inside an inline table is dropped")
    func nulls() {
        let inArray = encode(.mapping([.init(key: "a", value: .sequence([.int(1), .null]))]))
        #expect(inArray.issues.map(\.code) == [.tomlNoNull])
        #expect(inArray.issues.first?.path.pathDescription == "a[1]")

        // A table member that is nil is simply absent — the one null TOML can express, by
        // not writing it. That holds for an inline table nested in an array as well.
        let inline = encode(
            .mapping([
                .init(
                    key: "points",
                    value: .sequence([
                        .sequence([
                            .mapping([
                                .init(key: "x", value: .int(1)),
                                .init(key: "gone", value: .null),
                                .init(key: "y", value: .double(0.5))
                            ])
                        ])
                    ]))
            ]))
        #expect(inline.issues.isEmpty)
        #expect(inline.text.contains("points = [[{x = 1, y = 0.5}]]"))
    }

    @Test("encodedTOML throws what diagnoseEncodeTOML reports")
    func throwing() {
        let bad = Collides(id: "a", rest: ["id": .string("b")])
        #expect(throws: AssayError.self) { _ = try bad.encodedTOML() }
        #expect(bad.diagnoseEncodeTOML().issues.map(\.code) == [.extrasKeyCollision])
    }
}

// MARK: - XML

@Suite("XML: refusals, and markup the tree keeps")
struct XMLRefusalTableTests {

    @Test(
        "each malformed document is refused under its own code",
        arguments: [
            ("<a", IssueCode.xmlUnterminatedTag, 2),
            ("<a b=\"1\"", .xmlUnterminatedTag, 8),
            ("<a></", .xmlBadName, 5),
            ("<a></a", .xmlUnterminatedTag, 6),
            ("<a></a x>", .xmlUnterminatedTag, 7),
            ("<a><!-- never closed </a>", .xmlUnterminatedComment, 25)
        ])
    func refused(doc: String, code: IssueCode, at: Int) {
        var sink = IssueSink(limits: .default)
        #expect(XML.decode(Array(doc.utf8), into: &sink) == nil, "\(doc)")
        #expect(sink.issues.map(\.code) == [code], "\(doc)")
        #expect(sink.issues.first?.location.map { Int($0.lo) } == at, "\(doc)")
    }

    @Test("a tag with attributes that never closes, and an entity nobody declared")
    func moreRefusals() {
        // What follows the attributes decides the code: something that cannot start a name
        // is a bad attribute name; a `/` that is not `/>` is a tag that never closed.
        for (doc, code) in [
            ("<a b=\"1\" !", IssueCode.xmlBadAttributeName),
            ("<a b=\"1\" /x>", .xmlUnterminatedTag)
        ] {
            var sink = IssueSink(limits: .default)
            #expect(XML.decode(Array(doc.utf8), into: &sink) == nil, "\(doc)")
            #expect(sink.issues.map(\.code) == [code], "\(doc)")
        }

        // Never passed through as text: that is how an XXE mitigation gets bypassed.
        for doc in ["<a>&nope;</a>", "<a b=\"&nope;\"/>"] {
            var s = IssueSink(limits: .default)
            #expect(XML.decode(Array(doc.utf8), into: &s) == nil, "\(doc)")
            #expect(s.issues.map(\.code) == [.xmlUndeclaredEntity], "\(doc)")
            #expect(s.issues.first?.params["entity"] == .string("nope"))
        }
    }

    @Test("a character reference XML forbids is refused, naming what was written")
    func characterReferences() {
        for bad in ["&#1;", "&#x110000;", "&#xD800;", "&#zz;"] {
            var sink = IssueSink(limits: .default)
            #expect(XML.decode(Array("<a>\(bad)</a>".utf8), into: &sink) == nil, "\(bad)")
            #expect(sink.issues.map(\.code) == [.xmlBadCharacterReference], "\(bad)")
            #expect(sink.issues.first?.received == bad)
        }
        // Tab, newline and carriage return are the three control characters it allows.
        var sink = IssueSink(limits: .default)
        let ok = XML.decode(Array("<a>&#9;&#x41;</a>".utf8), into: &sink)
        #expect(ok?.root.text == "\tA")
    }

    @Test("a DOCTYPE that never closes is refused; odd entity declarations are skipped")
    func doctype() {
        var sink = IssueSink(limits: .default)
        #expect(XML.decode(Array("<!DOCTYPE a [<!ENTITY % p \"x\"".utf8), into: &sink) == nil)
        #expect(sink.issues.map(\.code).contains(.xmlUnterminatedDoctype))

        // A parameter entity and a declaration with no legal name declare nothing, and the
        // document after them still parses. Neither is expanded: there is no `%p;` support.
        for subset in ["<!ENTITY % p \"x\">", "<!ENTITY 1bad \"x\">"] {
            var s = IssueSink(limits: .default)
            let d = XML.decode(Array("<!DOCTYPE a [\(subset)]><a/>".utf8), into: &s)
            #expect(d != nil && s.isValid, "\(subset)")
        }
    }

    @Test("processing instructions are kept: in the prolog and inside an element")
    func processingInstructions() throws {
        let d = try XML.parse(#"<?xml version="1.0"?><?pi data?><a><?target some data?></a>"#)
        #expect(d.prolog.contains(.processingInstruction(target: "pi", data: "data")))
        #expect(d.root.children == [.processingInstruction(target: "target", data: "some data")])
    }

    @Test("xml: is the one prefix that needs no declaration")
    func xmlPrefix() throws {
        let d = try XML.parse(#"<a xml:lang="en" plain="p"/>"#)
        let xmlLang = XML.Name("lang", namespaceURI: "http://www.w3.org/XML/1998/namespace")
        #expect(d.root[attribute: xmlLang] == "en")
        #expect(d.root[attribute: XML.Name("plain")] == "p")
        #expect(d.root[attribute: XML.Name("absent")] == nil)
        #expect(d.root[attribute: "plain"] == "p")
    }

    @Test("the document-level limits: maxBytes and invalid UTF-8")
    func limits() {
        var small = Limits.default
        small.maxBytes = 4
        var sink = IssueSink(limits: small)
        #expect(XML.decode(Array("<abcdef/>".utf8), into: &sink, limits: small) == nil)
        #expect(sink.issues.map(\.code) == [.tooManyBytes])

        var sink2 = IssueSink(limits: .default)
        #expect(XML.decode(Array("<a>".utf8) + [0xFF] + Array("</a>".utf8), into: &sink2) == nil)
        #expect(sink2.issues.map(\.code) == [.invalidUTF8])
    }

    @Test("elements and attributes compare and hash by content, not by span")
    func hashing() throws {
        let a = try XML.parse(#"<r k="v"><c>t</c></r>"#).root
        let b = try XML.parse("\n\n" + #"<r   k="v"><c>t</c></r>"#).root
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        #expect(Set(a.attributes + b.attributes).count == 1)
        #expect(a != (try XML.parse(#"<r k="w"><c>t</c></r>"#).root))
        // A text node is not an element.
        #expect(a.children.first?.element != nil)
        #expect(XML.Node.text("t").element == nil)
    }
}

// MARK: - Property lists

@Suite("XML plists: structure the format forbids")
struct XMLPlistStructureTests {

    private func decode(_ body: String) -> (RawValue?, [AssayCore.Issue]) {
        var sink = IssueSink(limits: .default)
        let v = Plist.decode(Array("<plist>\(body)</plist>".utf8), into: &sink, limits: .default)
        return (v, sink.issues)
    }

    @Test("two keys in a row, and an element that is not a plist type")
    func refusals() {
        let (v1, i1) = decode("<dict><key>a</key><key>b</key><string>x</string></dict>")
        #expect(v1 == nil && i1.map(\.code) == [.plistUnpairedKey])
        let (v2, i2) = decode("<array><string>x</string><bogus/></array>")
        #expect(v2 == nil && i2.map(\.code) == [.plistBadMarker])
        #expect(i2.first?.message.contains("<bogus>") == true)
    }

    @Test("a date is its text, with the whitespace around it trimmed")
    func date() {
        let (v, issues) = decode("<dict><key>d</key><date> 2024-01-01T00:00:00Z </date></dict>")
        #expect(issues.isEmpty)
        #expect(v?["d"]?.string == "2024-01-01T00:00:00Z")
    }
}

@Suite("Binary plists: markers, lengths and the trailer")
struct BinaryPlistArmTests {

    private func codes(_ bytes: [UInt8]) -> [IssueCode] {
        var sink = IssueSink(limits: .default)
        _ = Plist.decode(bytes, into: &sink, limits: .default)
        return sink.issues.map(\.code)
    }

    private func value(_ bytes: [UInt8]) -> RawValue? {
        var sink = IssueSink(limits: .default)
        return Plist.decode(bytes, into: &sink, limits: .default)
    }

    /// A document whose only object is `body`.
    private func single(_ body: [UInt8]) -> [UInt8] {
        var b = BPlistBuilder()
        let top = b.add(body)
        return b.finish(top: top)
    }

    @Test(
        "an object the format does not define, or one that runs past the objects, is refused",
        arguments: [
            ([0x0F] as [UInt8], IssueCode.plistBadMarker),  // the fill byte is not a value
            ([0x70], .plistBadMarker),  // no such object type
            ([0x15], .plistTruncated),  // a 32-byte integer
            ([0x5E, 0x41], .plistTruncated),  // 14 ASCII bytes promised, one present
            ([0x8F], .plistTruncated),  // a 16-byte UID
            ([0x51, 0xE9], .plistBadString)  // a non-ASCII byte in an ASCII string
        ])
    func objects(body: [UInt8], code: IssueCode) {
        #expect(codes(single(body)) == [code], "\(body)")
    }

    @Test("a dictionary that is its own value is a cycle")
    func selfContainingDictionary() {
        var b = BPlistBuilder()
        let key = b.add(BPlistBuilder.asciiString("k"))
        let dict = b.add([0xD1, UInt8(key), 1])  // object 1 is this dictionary
        #expect(codes(b.finish(top: dict)) == [.plistCycle])
    }

    @Test("the 0xF count escape, with a count that is honest")
    func countEscape() {
        var b = BPlistBuilder()
        let x = b.add(BPlistBuilder.int(7))
        let top = b.add(BPlistBuilder.bigArray([x, x], refSize: 1))
        #expect(value(b.finish(top: top)) == .sequence([.int(7), .int(7)]))

        // Twenty elements is past what the marker's own nibble can count, which is when a
        // real writer uses the escape; three hundred needs the two-byte count.
        for n in [20, 300] {
            var w = BPlistBuilder()
            let leaf = w.add(BPlistBuilder.int(1))
            let wide = w.add(BPlistBuilder.bigArray(Array(repeating: leaf, count: n), refSize: 1))
            let doc = w.finish(top: wide, offsetSize: 2)
            #expect(value(doc)?.sequence?.count == n, "\(n)")
        }
    }

    @Test("UTF-16: a surrogate pair is one scalar; a high surrogate with no low is refused")
    func utf16Pairs() {
        // U+1F600 as D83D DE00, then 'A'.
        #expect(value(single([0x63, 0xD8, 0x3D, 0xDE, 0x00, 0x00, 0x41])) == .string("😀A"))
        #expect(codes(single([0x62, 0xD8, 0x3D, 0x00, 0x41])) == [.plistBadString])
        #expect(codes(single([0x61, 0xD8, 0x3D])) == [.plistBadString])
    }

    @Test("<data> of one, two and three bytes pads to the same base64 Foundation writes")
    func base64Padding() {
        #expect(value(single([0x41, 0x41])) == .string("QQ=="))
        #expect(value(single([0x42, 0x41, 0x42])) == .string("QUI="))
        #expect(value(single([0x43, 0x41, 0x42, 0x43])) == .string("QUJD"))
        #expect(Data(base64Encoded: "QQ==") == Data([0x41]))
    }

    /// The trailer is the last 32 bytes, and every field in it is a number the file chose.
    @Test("a trailer that points outside the file is refused before anything is read through it")
    func trailer() {
        let good = single(BPlistBuilder.int(7))
        #expect(value(good) == .int(7))
        let t = good.count - 32

        var topOutside = good
        topOutside[t + 23] = 9  // top object 9 of 1
        #expect(codes(topOutside) == [.plistBadTrailer])

        var tableBeforeMagic = good
        tableBeforeMagic[t + 31] = 1  // offset table "at byte 1", inside the magic
        #expect(codes(tableBeforeMagic) == [.plistBadTrailer])

        // The single offset-table entry is the byte just before the trailer.
        var offsetPastFile = good
        offsetPastFile[t - 1] = 0xFF
        #expect(codes(offsetPastFile) == [.plistBadOffset])

        var offsetIntoTrailer = good
        offsetIntoTrailer[t - 1] = UInt8(good.count - 10)
        #expect(codes(offsetIntoTrailer) == [.plistBadOffset])
    }
}

// MARK: - MappedFile

@Suite("MappedFile: what cannot be mapped")
struct MappedFileErrorTests {

    @Test("a URL that is not a file URL is refused before any system call")
    func notAFile() throws {
        let url = try #require(URL(string: "https://example.com/x.json"))
        do {
            _ = try MappedFile.open(url)
            Issue.record("expected a throw")
        } catch let e as MappedFileError {
            #expect(e.description == "mmap requires a file URL, got \(url)")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("a missing path says which path, and why")
    func missing() {
        #expect(throws: MappedFileError.self) {
            _ = try MappedFile.open(path: "/nonexistent/assay/none.json")
        }
        do {
            _ = try MappedFile.open(path: "/nonexistent/assay/none.json")
        } catch {
            #expect("\(error)".contains("/nonexistent/assay/none.json"))
        }
    }
}
