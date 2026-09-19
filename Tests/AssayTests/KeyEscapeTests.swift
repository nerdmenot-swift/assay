// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay

//===----------------------------------------------------------------------===//
// Document keys written with JSON escapes. RFC 8259: `"a\/b"`, `"café"` and `"a/b"`,
// `"café"` are the same keys as their unescaped forms. Until 2026-09-19 the decoder matched
// keys on raw bytes, so an escaped key never matched its field: Python's `json.dumps`, which
// escapes every non-ASCII character by default, produced documents whose `café` field was
// reported MISSING. Every dispatch shape an escaped key can reach is covered here.
//===----------------------------------------------------------------------===//

@Schema struct KEPlain: Equatable { @Key("café") var cafe: Int; var name: String }

/// Past the global window's ceiling, so dispatch is by length bucket.
@Schema struct KEWide: Equatable {
    var alpha: Int; var bravo: Int; var charlie: Int; var delta: Int; var echo: Int
    var foxtrot: Int; var golf: Int; var hotel: Int; var india: Int; var juliet: Int
    var kilo: Int; var lima: Int; var mike: Int; var november: Int
}

@Schema struct KEAlias: Equatable { @Key("naïve", or: "näive") var word: String }

@Schema struct KEPath: Equatable { @Key(path: "prófile.nàme") var name: String }

@Schema(unknownKeys: .reject) struct KEStrict: Equatable { var known: Int }

@Suite("Escaped document keys")
struct KeyEscapeTests {

    @Test("unicode, slash and quote escapes in keys match their fields")
    func plain() throws {
        #expect(try KEPlain.parse(json: #"{"café":1,"name":"x"}"#) == KEPlain(cafe: 1, name: "x"))
        #expect(try KEPlain.parse(json: #"{"café":1,"name":"x"}"#) == KEPlain(cafe: 1, name: "x"))
    }

    @Test("Python json.dumps default output decodes")
    func pythonEnsureASCII() throws {
        // json.dumps({"café": 1, "name": "x"}) with the default ensure_ascii=True.
        #expect(try KEPlain.parse(json: #"{"café": 1, "name": "x"}"#).cafe == 1)
    }

    @Test("length-bucket dispatch, past the window's ceiling")
    func wide() throws {
        let v = try KEWide.parse(json: """
            {"alpha":1,"br\\u0061vo":2,"charlie":3,"delt\\u0061":4,"echo":5,"foxtrot":6,
             "golf":7,"hotel":8,"india":9,"juliet":10,"kilo":11,"lima":12,"mike":13,
             "nov\\u0065mber":14}
            """)
        #expect(v.bravo == 2 && v.delta == 4 && v.november == 14)
    }

    @Test("an escaped ALIAS matches, and says so")
    func alias() {
        let d = KEAlias.diagnose(json: #"{"näive":"x"}"#)
        #expect(d.value?.word == "x")
        #expect(d.warnings.map(\.code.codeString) == ["alias_matched"])
    }

    @Test("escaped segments inside a @Key(path:)")
    func path() throws {
        #expect(try KEPath.parse(json: #"{"prófile":{"nàme":"x"}}"#).name == "x")
    }

    @Test("an escaped UNKNOWN key is reported by its unescaped name")
    func unknown() {
        let d = KEStrict.diagnose(json: #"{"known":1,"unknown":2}"#)
        #expect(d.issues.map(\.code.codeString) == ["unknown_key"])
        #expect(d.issues.first?.received == "unknown")
    }

    @Test("an invalid escape in a key is a malformed document, not a crash")
    func invalid() {
        let d = KEPlain.diagnose(json: #"{"caf\q":1,"name":"x"}"#)
        #expect(d.value == nil)
        #expect(d.issues.map(\.code.codeString).contains("malformed_document"))
    }

    @Test("many escaped keys in one document reuse one scratch buffer correctly")
    func many() throws {
        let body = (0..<50).map { #""ké\#($0)":\#($0)"# }.joined(separator: ",")
        #expect(try KEPlain.parse(json: #"{"café":7,"# + body + #","name":"x"}"#).cafe == 7)
    }
}
