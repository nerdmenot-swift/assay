// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `@Wraps`, built 2026-09-08. EXPERIENCE §8, ROADMAP §6.
//
// The load-bearing test here is `identicalToAValidatedField`: `@Validate(.email)` on a
// `String` field and a `@Wraps`-generated `EmailAddress` field must produce BYTE-IDENTICAL
// issues — same code, same path, same params. That equivalence is the feature. If a wrapper
// reported differently, it would be a second validation mechanism wearing the first one's
// vocabulary, which is exactly what this library refuses elsewhere.
//===----------------------------------------------------------------------===//

import Testing
import Assay
import AssayCore
import AssayYAML

@Wraps(String.self, .email)
struct WrappedEmail {}

@Wraps(String.self, .min(3), .max(8))
struct Username {}

@Wraps(Int64.self, .range(1...100))
struct Percent {}

/// No rules at all — a wrapper that exists purely for type safety.
@Wraps(String.self)
struct OpaqueToken {}

@Schema(formats: .all)
struct WrapSignup: Equatable {
    var email: WrappedEmail
    var handle: Username
}

/// The comparison target: the same rule, spelled the ordinary way.
@Schema
struct PlainSignup: Equatable {
    @Validate(.email) var email: String
}

@Suite("@Wraps")
struct WrapsTests {

    @Test("a wrapper decodes as an ordinary field")
    func decodes() throws {
        let s = try WrapSignup.parse(json: Array(
            #"{"email":"ada@example.com","handle":"ada"}"#.utf8))
        #expect(s.email.raw == "ada@example.com")
        #expect(s.handle.raw == "ada")
    }

    /// **The equivalence that is the feature.** A wrapper is not a second validation
    /// mechanism; it is the same one, reached differently.
    @Test("a wrapper reports identically to a validated field")
    func identicalToAValidatedField() {
        let wrapped = WrapSignup.diagnose(json: Array(
            #"{"email":"nope","handle":"ada"}"#.utf8))
        let plain = PlainSignup.diagnose(json: Array(#"{"email":"nope"}"#.utf8))

        let a = try? #require(wrapped.issues.first)
        let b = try? #require(plain.issues.first)
        #expect(a?.code == b?.code, "\(String(describing: a?.code)) vs \(String(describing: b?.code))")
        #expect(a?.path == b?.path)
        #expect(a?.params["message"] == b?.params["message"])
    }

    /// One rule array, two callers. This is what makes "cannot hold an invalid value" true
    /// rather than nearly true.
    @Test("init? runs the same rules the decoder runs")
    func initValidates() {
        #expect(WrappedEmail("ada@example.com") != nil)
        #expect(WrappedEmail("nope") == nil)
        #expect(Username("ab") == nil, "below .min(3)")
        #expect(Username("abcdefghi") == nil, "above .max(8)")
        #expect(Username("ada") != nil)
        #expect(Percent(50) != nil)
        #expect(Percent(0) == nil)
    }

    @Test("a wrapper with no rules accepts anything of the wrapped type")
    func noRules() {
        #expect(OpaqueToken("") != nil)
        #expect(OpaqueToken("anything at all") != nil)
    }

    @Test("the generated conformances are real")
    func conformances() {
        let a = WrappedEmail("ada@example.com")
        let b = WrappedEmail("ada@example.com")
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        #expect(String(describing: a!) == "ada@example.com")
    }

    /// The `AssayerBacked` conformance is what carries this, so both tree paths work with no
    /// per-format code in the macro.
    @Test("a wrapper decodes from YAML too")
    func yaml() throws {
        let s = try WrapSignup.parse(yaml: "email: ada@example.com\nhandle: ada\n")
        #expect(s.email.raw == "ada@example.com")
    }

    @Test("a non-scalar wrapped type is refused at expansion")
    func nonScalarRefused() {
        let (_, diags) = expandWrapsForTesting("@Wraps(Foo.self) struct W {}")
        #expect(diags.contains { $0.contains("write the `AssayerBacked` conformance by hand") },
                "got \(diags)")
    }

    /// The same expansion-time rule/type check `@Validate` gets. `.email` on a number is a
    /// compile error in both places, and for the same reason.
    @Test("a rule that does not apply to the wrapped type is refused")
    func ruleTypeChecked() {
        let (_, diags) = expandWrapsForTesting("@Wraps(Int64.self, .email) struct W {}")
        #expect(diags.contains { $0.contains(".email") && $0.contains("Int64") }, "got \(diags)")
    }

    @Test("a stored property in the body is refused, since the storage is generated")
    func storedPropertyRefused() {
        let (_, diags) = expandWrapsForTesting("@Wraps(String.self) struct W { var x: Int }")
        #expect(diags.contains { $0.contains("must not declare a stored property") },
                "got \(diags)")
    }
}
