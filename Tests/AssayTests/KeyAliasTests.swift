// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import Assay
import AssayCore
import AssayYAML
import AssayTOML

// Wire keys are arbitrary strings: spaces, punctuation, unicode. A field's name is a Swift
// identifier and its key is whatever the document calls it, on every path.

@Schema(formats: .all, encodes: true)
struct Spaced: Equatable {
    @Key("first name") var firstName: String
    @Key("e-mail", or: "email address", "E-Mail") var email: String
    @Key("ünïcödé key") var unicode: Int
    @Key("count (items)") var count: Int = 0
}

@Suite("Keys with spaces and punctuation, and aliases, on every path")
struct KeyAliasTests {

    @Test("JSON")
    func json() throws {
        let v = try Spaced.parse(json: #"{"first name":"Ada","e-mail":"a@x.io","ünïcödé key":3,"count (items)":2}"#)
        #expect(v == Spaced(firstName: "Ada", email: "a@x.io", unicode: 3, count: 2))
        let d = Spaced.diagnose(json: #"{"first name":"Ada","email address":"a@x.io","ünïcödé key":3}"#)
        #expect(d.value?.email == "a@x.io")
        #expect(d.isValid)
        #expect(d.warnings.map(\.code.codeString) == ["alias_matched"], "\(d.warnings)")
        #expect(d.warnings.first?.path.pathDescription == "e-mail")
        #expect(d.warnings.first?.message.contains("email address") == true)
    }

    @Test("YAML and TOML")
    func yamlAndToml() throws {
        let y = try Spaced.parse(yaml: "\"first name\": Ada\nE-Mail: a@x.io\n\"ünïcödé key\": 3\n")
        #expect(y.email == "a@x.io")
        let t = Spaced.diagnose(toml: "\"first name\" = \"Ada\"\n\"email address\" = \"a@x.io\"\n\"ünïcödé key\" = 3\n")
        #expect(t.value?.email == "a@x.io")
        #expect(t.warnings.map(\.code.codeString) == ["alias_matched"])
    }

    @Test("encoding writes the primary key, quoted as the format requires")
    func encode() throws {
        let v = Spaced(firstName: "Ada", email: "a@x.io", unicode: 3, count: 1)
        #expect(try v.jsonText().contains(#""first name":"Ada""#))
        #expect(try v.tomlText().contains(#""first name" = "Ada""#))
        #expect(try v.tomlText().contains(#"e-mail = "a@x.io""#), "a bare key: `-` is a bare-key character")
        #expect(try Spaced.parse(toml: try v.tomlText()) == v)
        #expect(try Spaced.parse(json: try v.encodedJSON().toArray()) == v)
    }
}
