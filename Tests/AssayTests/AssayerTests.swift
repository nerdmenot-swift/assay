// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `Assayer<T>` and `AssayerBacked`, built 2026-09-08. ROADMAP §7, docs/ASSAYER.md.
//
// The load-bearing test in this file is `wrapperIsAnOrdinaryField`. The design's whole claim
// is that a conforming type is ALREADY a nested schema type as far as the macro is
// concerned, so no macro change is needed. If that test needs `CodeGen.swift` touched to
// pass, the design is wrong and the right move is to stop rather than to make it fit.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayCore
import AssayYAML

// MARK: - A domain scalar: the case @Schema has no spelling for

struct EmailAddress: Equatable, Sendable {
    var raw: String
}

extension EmailAddress: AssayerBacked {
    nonisolated static let assaySchema =
        Assayer.string.validate(.email).map(EmailAddress.init(raw:))
}

/// A wrapper whose conversion can refuse a value the rules accepted — `map` is failable on
/// purpose, and the refusal has to be reported rather than swallowed.
struct EvenNumber: Equatable, Sendable {
    var value: Int64
}

extension EvenNumber: AssayerBacked {
    nonisolated static let assaySchema =
        Assayer.int.map { $0 % 2 == 0 ? EvenNumber(value: $0) : nil }
}

@Schema(formats: .all)
struct MailAccount: Equatable {
    var email: EmailAddress
    var name: String
}

@Schema struct EvenHolder: Equatable { var n: EvenNumber }
@Schema struct ManyMails: Equatable { var to: [EmailAddress]; var cc: EmailAddress? }

@Suite("AssayerBacked as a field type")
struct AssayerBackedTests {

    /// **The checkpoint.** A wrapper type used as an ordinary field, decoded through the
    /// ordinary door, with no macro change of any kind.
    @Test("a wrapper type is an ordinary field")
    func wrapperIsAnOrdinaryField() throws {
        let a = try MailAccount.parse(json: Array(#"{"email":"ada@example.com","name":"Ada"}"#.utf8))
        #expect(a.email == EmailAddress(raw: "ada@example.com"))
        #expect(a.name == "Ada")
    }

    /// The rules are the same `Rule` values `@Validate` uses, so they report the same way.
    @Test("a rule failure inside a wrapper names the field")
    func ruleFailureNamesField() {
        let d = MailAccount.diagnose(json: Array(#"{"email":"nope","name":"Ada"}"#.utf8))
        #expect(!d.isValid)
        #expect(d.issues.first?.path == [.key("email")], "\(d.issues.map(\.path))")
    }

    /// Both tree paths route through one plan, so YAML works with no additional code. That
    /// is the property that makes the two interpreters worth having rather than one.
    @Test("the same wrapper decodes from YAML with no extra work")
    func yamlForFree() throws {
        let a = try MailAccount.parse(yaml: "email: ada@example.com\nname: Ada\n")
        #expect(a.email.raw == "ada@example.com")
    }

    /// A conversion that refuses must produce an issue, not a silent nil the caller cannot
    /// explain.
    @Test("a failing conversion is reported")
    func conversionFailureReported() {
        let ok = EvenHolder.diagnose(json: Array(#"{"n": 4}"#.utf8))
        #expect(ok.isValid)

        let bad = EvenHolder.diagnose(json: Array(#"{"n": 5}"#.utf8))
        #expect(!bad.isValid)
        #expect(bad.issues.contains { $0.code == .custom("assayer_conversion_failed") },
                "\(bad.issues.map(\.code))")
    }

    /// A wrapper in an array and in an optional — the shapes that would break if the
    /// conformance only worked at the top level of a field.
    @Test("wrappers work in arrays and optionals")
    func collections() throws {
        let m = try ManyMails.parse(json: Array(
            #"{"to":["a@e.com","b@e.com"],"cc":null}"#.utf8))
        #expect(m.to.count == 2)
        #expect(m.cc == nil)
    }
}

@Suite("Assayer as a value")
struct AssayerValueTests {

    /// A plan that refers to itself forever. `@Sendable` because `Assayer.lazy` takes one —
    /// which is itself the reason `Assayer` can be a `static let`.
    @Sendable static func cyclic() -> Assayer<RawValue> {
        Assayer.lazy { Assayer.object([.init("next", cyclic())]) }
    }

    /// The other half: a schema with no declaration at all.
    @Test("a runtime-built object schema decodes")
    func dynamicObject() throws {
        let schema = Assayer.object([
            .init("name", .raw),
            .init("nickname", .raw, optional: true),
        ])
        let v = try schema.parse(json: Array(#"{"name":"Ada"}"#.utf8))
        #expect(v["name"] == .string("Ada"))
    }

    @Test("a missing required field is reported, an optional one is not")
    func presence() {
        let schema = Assayer.object([
            .init("required", .raw),
            .init("optional", .raw, optional: true),
        ])
        let d = schema.diagnose(json: Array(#"{}"#.utf8))
        #expect(!d.isValid)
        #expect(d.issues.count == 1)
        #expect(d.issues.first?.path == [.key("required")])
    }

    @Test("leaves type-check, and a mismatch names the path")
    func leafTypes() {
        let schema = Assayer.object([.init("n", Assayer.int.map { RawValue.int($0) })])
        let d = schema.diagnose(json: Array(#"{"n": "text"}"#.utf8))
        #expect(!d.isValid)
        #expect(d.issues.first?.path == [.key("n")])
    }

    @Test("rules apply to a value schema exactly as to a declared one")
    func rules() {
        let schema = Assayer.string.validate(.min(3))
        #expect((try? schema.parse(json: Array(#""abcd""#.utf8))) == "abcd")
        #expect(schema.diagnose(json: Array(#""ab""#.utf8)).isValid == false)
    }

    /// **The denial-of-service surface the static door does not have.** A runtime plan can
    /// contain a `.lazy` cycle that no macro-emitted schema can, so the `RawValue`
    /// interpreter charges depth itself rather than relying on `AssayReader`.
    @Test("a recursive plan is bounded by maxDepth rather than looping")
    func recursionIsBounded() {
        var json = ""
        for _ in 0..<200 { json += #"{"next":"# }
        json += "null"
        for _ in 0..<200 { json += "}" }

        let d = Self.cyclic().diagnose(json: Array(json.utf8), limits: .default)
        #expect(!d.isValid)
        #expect(d.issues.contains { $0.code == .depthExceeded },
                "must be refused by the depth limit, not by running out of stack")
    }

    @Test("arrays and optionals compose")
    func composition() throws {
        let schema = Assayer.array(of: Assayer.string.validate(.min(1)))
        let v = try schema.parse(json: Array(#"["a","bb"]"#.utf8))
        #expect(v == ["a", "bb"])
    }
}
