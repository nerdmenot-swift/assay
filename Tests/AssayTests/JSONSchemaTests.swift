// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `jsonSchema(for:)`, built 2026-09-09. EXPERIENCE §14, ROADMAP §11.
//
// The load-bearing suite is `SchemaIsNotTooStrict`. A generated JSON Schema has one failure
// mode that matters far more than the others: **describing the type as stricter than it is.**
// A schema that under-documents costs a reader some guessing; a schema that rejects documents
// the type actually accepts makes a correct client unusable, and the client author has no way
// to discover that the schema is wrong rather than their code.
//
// So the rule the renderer holds — *when in doubt, describe MORE than the type accepts, never
// less* — is tested by decoding documents that the schema must not have excluded, rather than
// by comparing rendered text to a golden string. Golden text tests are also here, but they
// check spelling; these check the property.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayCore

@Schema(keys: .snakeCase, describes: true)
struct SchemaArticle: Equatable {
    @Validate(.min(1), .max(120)) var title: String
    @Validate(.url) var link: String
    @Validate(.range(1...600)) var readingMinutes: Int
    var tags: [String] = []
    var summary: String?
}

@Schema(keys: .snakeCase, unknownKeys: .reject, describes: true)
struct SchemaStrictDoc: Equatable {
    var name: String
}

@Schema(describes: true)
struct SchemaAuthor: Equatable {
    @Validate(.email) var email: String
    var name: String
}

@Schema(describes: true)
struct SchemaPost: Equatable {
    var title: String
    var author: SchemaAuthor
    var reviewers: [SchemaAuthor]
    var counts: [String: Int]
}

/// `.trimmed`/`.lowercased`: assertions with no exact JSON Schema keyword.
@Schema(describes: true)
struct SchemaNormalised: Equatable {
    @Validate(.trimmed, .lowercased, .min(2)) var handle: String
}

/// `@Transform` — the only place `.input` and `.output` differ.
@Schema(keys: .snakeCase, describes: true)
struct SchemaTicket: Equatable {
    @Transform({ (s: String) in s.count }) var code: Int
    var name: String
}

/// Aliases and rules that map to `format`.
@Schema(keys: .snakeCase, describes: true)
struct SchemaContact: Equatable {
    @Key("email", or: "email_address") @Validate(.email) var email: String
    @Validate(.uuid) var id: String
    @Validate(.oneOf(["admin", "member"])) var role: String
    @Validate(.each(.min(1)), .unique) var labels: [String]
}

private func find(_ v: JSONSchemaValue, _ path: [String]) -> JSONSchemaValue? {
    var current = v
    for key in path {
        guard case .object(let members) = current,
              let next = members.first(where: { $0.0 == key })?.1 else { return nil }
        current = next
    }
    return current
}

private func str(_ v: JSONSchemaValue?) -> String? {
    if case .string(let s) = v { return s }
    return nil
}

private func num(_ v: JSONSchemaValue?) -> Double? {
    if case .number(let d) = v { return d }
    return nil
}

@Suite("jsonSchema(for:)")
struct JSONSchemaTests {

    @Test("the document names the 2020-12 dialect and the type")
    func envelope() {
        let s = SchemaArticle.jsonSchema()
        #expect(str(find(s, ["$schema"]))
                == "https://json-schema.org/draft/2020-12/schema")
        #expect(str(find(s, ["title"])) == "SchemaArticle")
        #expect(str(find(s, ["type"])) == "object")
    }

    /// Wire keys, not property names — the whole point of `@Schema(keys:)` being compile-time.
    @Test("properties use wire keys")
    func wireKeys() {
        let s = SchemaArticle.jsonSchema()
        #expect(find(s, ["properties", "reading_minutes"]) != nil)
        #expect(find(s, ["properties", "readingMinutes"]) == nil)
    }

    /// The five presence states collapse to one JSON Schema question: is it in `required`?
    @Test("required covers exactly the fields with no default and no optionality")
    func required() {
        guard case .array(let req)? = find(SchemaArticle.jsonSchema(), ["required"]) else {
            Issue.record("no required array"); return
        }
        let names = Set(req.compactMap { str($0) })
        #expect(names == ["title", "link", "reading_minutes"])
        #expect(!names.contains("tags"), "a defaulted field is not required")
        #expect(!names.contains("summary"), "an optional field is not required")
    }

    @Test("a rule's keyword depends on the field's type")
    func keywordDependsOnType() {
        let s = SchemaArticle.jsonSchema()
        // .min(1)/.max(120) on a String
        #expect(num(find(s, ["properties", "title", "minLength"])) == 1)
        #expect(num(find(s, ["properties", "title", "maxLength"])) == 120)
        // .range(1...600) on an Int
        #expect(num(find(s, ["properties", "reading_minutes", "minimum"])) == 1)
        #expect(num(find(s, ["properties", "reading_minutes", "maximum"])) == 600)
        #expect(str(find(s, ["properties", "reading_minutes", "type"])) == "integer")
    }

    @Test("format rules become format keywords")
    func formats() {
        #expect(str(find(SchemaArticle.jsonSchema(), ["properties", "link", "format"])) == "uri")
        #expect(str(find(SchemaContact.jsonSchema(), ["properties", "id", "format"])) == "uuid")
        #expect(str(find(SchemaContact.jsonSchema(), ["properties", "email", "format"])) == "email")
    }

    @Test("oneOf becomes enum, unique becomes uniqueItems, each lands on items")
    func collectionsAndEnums() {
        let s = SchemaContact.jsonSchema()
        guard case .array(let values)? = find(s, ["properties", "role", "enum"]) else {
            Issue.record("no enum"); return
        }
        #expect(values.compactMap { str($0) } == ["admin", "member"])
        #expect(find(s, ["properties", "labels", "uniqueItems"]) != nil)
        #expect(num(find(s, ["properties", "labels", "items", "minLength"])) == 1,
                ".each's rules belong on the element, which is where JSON Schema puts them")
    }

    @Test("an optional is a nullable type union, not a missing property")
    func optionals() {
        guard case .array(let types)? =
                find(SchemaArticle.jsonSchema(), ["properties", "summary", "type"]) else {
            Issue.record("summary's type is not a union"); return
        }
        #expect(types.compactMap { str($0) } == ["string", "null"])
    }

    @Test("nested schema types are inlined, and collections of them too")
    func nested() {
        let s = SchemaPost.jsonSchema()
        #expect(str(find(s, ["properties", "author", "type"])) == "object")
        #expect(str(find(s, ["properties", "author", "properties", "email", "format"]))
                == "email")
        #expect(str(find(s, ["properties", "reviewers", "type"])) == "array")
        #expect(str(find(s, ["properties", "reviewers", "items", "properties", "name", "type"]))
                == "string")
        // [String: Int] is an object with a constrained additionalProperties.
        #expect(str(find(s, ["properties", "counts", "additionalProperties", "type"]))
                == "integer")
    }

    /// `.reject` is the only policy that means `additionalProperties: false`. `.warn` and
    /// `.collect` still accept the document, and a schema saying otherwise would refuse
    /// documents this very type reads.
    @Test("additionalProperties: false only for unknownKeys: .reject")
    func additionalProperties() {
        #expect(find(SchemaStrictDoc.jsonSchema(), ["additionalProperties"]) != nil)
        #expect(find(SchemaArticle.jsonSchema(), ["additionalProperties"]) == nil)
    }

    @Test("input and output differ exactly where a transform is")
    func inputVersusOutput() {
        let input = SchemaTicket.jsonSchema(for: .input)
        let output = SchemaTicket.jsonSchema(for: .output)
        #expect(str(find(input, ["properties", "code", "type"])) == "string",
                "a producer must send what the transform consumes")
        #expect(str(find(output, ["properties", "code", "type"])) == "integer",
                "a consumer receives the declared property type")
        // A field with no transform is identical in both.
        #expect(str(find(input, ["properties", "name", "type"])) == "string")
        #expect(str(find(output, ["properties", "name", "type"])) == "string")
    }

    @Test("the text renders as valid-looking JSON with stable key order")
    func text() {
        let t = SchemaArticle.jsonSchemaText()
        #expect(t.hasPrefix("{\n  \"$schema\""))
        #expect(t.contains("\"title\": \"SchemaArticle\""))
        #expect(t.contains("\"reading_minutes\""))
        // Rendered twice, identical: member order is declaration order, not a dictionary's.
        #expect(t == SchemaArticle.jsonSchemaText())
    }
}

@Suite("jsonSchema(for:) — never stricter than the type")
struct SchemaIsNotTooStrict {

    /// **The property that matters, and a comment in the renderer got it wrong until this
    /// test ran.** `.trimmed` and `.lowercased` are ASSERTIONS — Assay reports `not_trimmed`,
    /// it does not trim. They still get no `pattern`, but for a different reason: no character
    /// class reproduces them exactly (`isTrimmed` is space/tab/CR/LF, ECMA-262's `\s` is
    /// wider; `.lowercased` is full Unicode case folding), and an approximate pattern could be
    /// NARROWER than the real check, which is the direction that must never happen.
    @Test("a rule with no exact keyword becomes prose, not an approximate pattern")
    func inexactRulesBecomeProse() throws {
        let s = SchemaNormalised.jsonSchema()
        #expect(find(s, ["properties", "handle", "pattern"]) == nil,
                "an approximate pattern could reject documents this type accepts")
        #expect(num(find(s, ["properties", "handle", "minLength"])) == 2,
                "the exactly-expressible constraint beside them must survive")
        let note = str(find(s, ["properties", "handle", "description"]))
        #expect(note?.contains("whitespace") == true, "got \(note ?? "nil")")
        #expect(note?.contains("lowercase") == true, "got \(note ?? "nil")")

        // And the rules really are assertions: this is rejected, not normalised.
        #expect(!SchemaNormalised.diagnose(json: #"{"handle":"  ADA  "}"#).isValid)
        #expect(try SchemaNormalised.parse(json: #"{"handle":"ada"}"#).handle == "ada")
    }

    /// An alias is a second spelling of one field. 2020-12 cannot say "exactly one of these",
    /// so both are described and neither is in `required` — permissive rather than wrong.
    @Test("an aliased field is described under both keys and required under neither")
    func aliases() throws {
        let s = SchemaContact.jsonSchema()
        #expect(find(s, ["properties", "email"]) != nil)
        #expect(find(s, ["properties", "email_address"]) != nil)
        if case .array(let req)? = find(s, ["required"]) {
            let names = Set(req.compactMap { str($0) })
            #expect(!names.contains("email"),
                    "requiring `email` would reject a document that used the alias")
            #expect(!names.contains("email_address"))
        }
        // Both really do decode.
        _ = try SchemaContact.parse(json: #"""
            {"email":"a@b.com","id":"6ba7b810-9dad-11d1-80b4-00c04fd430c8",\
            "role":"admin","labels":["x"]}
            """#.replacingOccurrences(of: "\\\n", with: ""))
        _ = try SchemaContact.parse(json: #"""
            {"email_address":"a@b.com","id":"6ba7b810-9dad-11d1-80b4-00c04fd430c8",\
            "role":"admin","labels":["x"]}
            """#.replacingOccurrences(of: "\\\n", with: ""))
    }

    /// A date bound has no 2020-12 keyword. It must not become `minimum`, which would compare
    /// a number against a string.
    @Test("a date bound is prose, not a numeric bound")
    func dateBounds() {
        let s = SchemaDated.jsonSchema()
        #expect(find(s, ["properties", "at", "minimum"]) == nil,
                "minimum on a date-time string would compare the wrong things")
        #expect(str(find(s, ["properties", "at", "format"])) == "date-time")
        #expect(str(find(s, ["properties", "at", "description"]))?.contains("after") == true)
    }

    /// A numeric date format is a number on the wire, and saying `date-time` would make a
    /// correct client emit a document this type rejects.
    @Test("a unix-format date is described as a number")
    func unixDate() {
        #expect(str(find(SchemaUnixDated.jsonSchema(), ["properties", "at", "type"])) == "number")
        #expect(find(SchemaUnixDated.jsonSchema(), ["properties", "at", "format"]) == nil)
    }
}

@Schema(describes: true)
struct SchemaDated: Equatable {
    @Validate(.after("2020-01-01T00:00:00Z")) var at: Date
}

@Schema(describes: true)
struct SchemaUnixDated: Equatable {
    @DateFormat(.unixSeconds) var at: Date
}

@Suite("jsonSchema(for:) — expansion-time refusals")
struct JSONSchemaDiagnostics {

    /// JSON Schema's `properties` is flat. Describing a `@Key(path:)` field would mean either
    /// inventing a top-level key no document has, or claiming a nested shape this type does
    /// not read. Refused, with the alternative named.
    @Test("describes: true with @Key(path:) is refused")
    func pathRefused() {
        let (_, diags) = expandSchemaForTesting("""
            @Schema(describes: true) struct S {
                @Key(path: "a.b") var b: String
            }
            """)
        #expect(diags.contains { $0.contains("@Key(path:) field") }, "got \(diags)")
    }

    /// An XML attribute is not a JSON property.
    @Test("describes: true with @XML placement is refused")
    func xmlRefused() {
        let (_, diags) = expandSchemaForTesting("""
            @Schema(formats: .all, describes: true) struct S {
                @XML(.attribute) var id: String
            }
            """)
        #expect(diags.contains { $0.contains("@XML placement") }, "got \(diags)")
    }
}
