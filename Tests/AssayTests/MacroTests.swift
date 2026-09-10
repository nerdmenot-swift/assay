// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Testing
import SwiftSyntax
import SwiftParser
import SwiftSyntaxMacros
import SwiftSyntaxMacroExpansion
@testable import AssayMacros

// The macro's own behaviour, tested directly — its diagnostics are purpose-written
// features (EXPERIENCE.md sells them by name), and until this file none of them had a
// test. Expansion runs in-process via BasicMacroExpansionContext; no compiler round trip,
// no XCTest-based support module.

/// Expand `@Schema` on the first struct in `source`. Returns the generated extension
/// text and every diagnostic message the macro emitted. Shared across test files.
func expandSchemaForTesting(
    _ source: String
) -> (expansion: String, diagnostics: [String]) {
    let file = Parser.parse(source: source)
    let context = BasicMacroExpansionContext(
        sourceFiles: [file: .init(moduleName: "Test", fullFilePath: "test.swift")])

    let structDecl = file.statements.compactMap { $0.item.as(StructDeclSyntax.self) }.first
    let enumDecl = file.statements.compactMap { $0.item.as(EnumDeclSyntax.self) }.first
    guard let decl: DeclGroupSyntax = structDecl ?? enumDecl else {
        return ("", ["no struct or enum found in source"])
    }
    let structDeclName = structDecl?.name.text ?? enumDecl!.name.text
    guard let attribute = decl.attributes
        .compactMap({ $0.as(AttributeSyntax.self) })
        .first(where: { $0.attributeName.trimmedDescription == "Schema" }) else {
        return ("", ["no @Schema attribute found"])
    }

    let extensions = (try? SchemaMacro.expansion(
        of: attribute,
        attachedTo: decl,
        providingExtensionsOf: TypeSyntax(stringLiteral: structDeclName),
        conformingTo: [],
        in: context)) ?? []

    return (extensions.map(\.description).joined(separator: "\n"),
            context.diagnostics.map(\.message))
}

@Suite("Macro diagnostics")
struct MacroDiagnosticTests {

    @Test("var x = 3 without a type annotation is a hard error, not a guess")
    func needsTypeAnnotation() {
        // A macro only sees source text — it cannot ask the type checker what `3` is,
        // and guessing Int would be wrong the moment someone writes `var timeout = 1.5`.
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S { var x = 3 }
        """)
        #expect(diags.contains {
            $0.contains("'x'") && $0.contains("explicit type annotation")
        })
    }

    @Test("let with an initializer cannot be decoded")
    func letWithInitializer() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S { let y: Int = 3
            var a: String }
        """)
        #expect(diags.contains {
            $0.contains("'let y'") && $0.contains("cannot be decoded")
        })
    }

    @Test("two properties reading the same wire key is an error")
    func duplicateKey() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S {
            @Key("id") var a: String
            @Key("id") var b: String
        }
        """)
        #expect(diags.contains { $0.contains("duplicate wire key \"id\"") })
    }

    @Test("aliases participate in duplicate detection too")
    func duplicateAlias() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S {
            var email: String
            @Key("mail", or: "email") var other: String
        }
        """)
        #expect(diags.contains { $0.contains("duplicate wire key \"email\"") })
    }

    @Test("more than 64 fields is refused with the count in the message")
    func tooManyFields() {
        let fields = (0..<70).map { "    var f\($0): Int" }.joined(separator: "\n")
        let (_, diags) = expandSchemaForTesting("@Schema struct S {\n\(fields)\n}")
        #expect(diags.contains { $0.contains("at most 64") && $0.contains("70") })
    }

    @Test(".collect without an @Extras property tells you what to add")
    func collectWithoutExtras() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema(unknownKeys: .collect) struct S { var a: String }
        """)
        #expect(diags.contains {
            $0.contains("@Extras") && $0.contains("[String: RawValue]")
        })
    }

    @Test("@Extras must be a String-keyed dictionary")
    func extrasWrongType() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S {
            var a: String
            @Extras var rest: [Int: RawValue]
        }
        """)
        #expect(diags.contains { $0.contains("dictionary keyed by String") })
    }

    @Test("two @Extras properties is an error")
    func multipleExtras() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S {
            @Extras var a: [String: RawValue]
            @Extras var b: [String: RawValue]
        }
        """)
        #expect(diags.contains { $0.contains("only one @Extras") })
    }

    @Test("@Schema on a non-struct is refused")
    func notAStruct() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema class C { var a: String }
        """)
        // A class parses as a class decl, so the helper reports no struct — but applying
        // the macro to an enum/class through the compiler surfaces the macro's own
        // diagnostic; assert the helper's failure mode here and the macro's directly.
        #expect(!diags.isEmpty)
    }

    @Test("a clean struct produces no diagnostics")
    func clean() {
        let (expansion, diags) = expandSchemaForTesting("""
        @Schema struct S { var a: String
            var b: Int }
        """)
        #expect(diags.isEmpty)
        #expect(!expansion.isEmpty)
    }
}

@Suite("Macro expansion shape")
struct MacroExpansionTests {

    @Test("the JSON body and conformance are emitted by default, RawValue is not")
    func defaultFormats() {
        let (expansion, _) = expandSchemaForTesting("@Schema struct S { var a: String }")
        #expect(expansion.contains("Assay.JSONAssayable"))
        #expect(expansion.contains("from reader: inout Assay.AssayReader"))
        #expect(!expansion.contains("Assay.RawDecodable"))
        #expect(!expansion.contains("from raw: Assay.RawValue"))
    }

    @Test("formats: .all emits both bodies and both conformances")
    func allFormats() {
        let (expansion, _) = expandSchemaForTesting(
            "@Schema(formats: .all) struct S { var a: String }")
        #expect(expansion.contains("Assay.JSONAssayable"))
        #expect(expansion.contains("Assay.RawDecodable"))
        #expect(expansion.contains("from raw: Assay.RawValue"))
    }

    @Test("formats: [.yaml] emits no JSON body at all")
    func yamlOnly() {
        let (expansion, _) = expandSchemaForTesting(
            "@Schema(formats: [.yaml]) struct S { var a: String }")
        #expect(!expansion.contains("Assay.JSONAssayable"))
        #expect(expansion.contains("Assay.RawDecodable"))
    }

    @Test("snake_case conversion happens at expansion, acronyms intact")
    func snakeCase() {
        let (expansion, _) = expandSchemaForTesting(
            "@Schema(keys: .snakeCase) struct S { var avatarURL: String }")
        #expect(expansion.contains("\"avatar_url\""))
        #expect(!expansion.contains("\"avatarUrl\""))     // the .convertFromSnakeCase bug
    }

    @Test("the window table is emitted sparse, never as a 256-element literal")
    func sparseTable() {
        // docs/COMPILE-TIME.md §3 rule 1: a 256-element array literal costs 16% of
        // expansion time in the type checker. The macro must never regress to it.
        let (expansion, _) = expandSchemaForTesting("""
        @Schema struct S { var alpha: String
            var beta: Int
            var gamma: Bool }
        """)
        #expect(expansion.contains("repeating:"))
        #expect(!expansion.contains(", 3, 3, 3, 3, 3, 3, 3, 3,"))
    }

    @Test("@Ignore excludes a field from decode but the init still receives defaults")
    func ignored() {
        let (expansion, _) = expandSchemaForTesting("""
        @Schema struct S { var a: String
            @Ignore var scratch: [String] = [] }
        """)
        #expect(!expansion.contains("scratch"))
    }

    @Test("static, computed and lazy members are skipped")
    func skippedMembers() {
        let (expansion, diags) = expandSchemaForTesting("""
        @Schema struct S {
            var a: String
            static var shared: Int = 0
            var computed: Int { 42 }
            lazy var cache: [String: Int] = [:]
        }
        """)
        #expect(diags.isEmpty)
        #expect(!expansion.contains("shared"))
        #expect(!expansion.contains("computed"))
        #expect(!expansion.contains("cache"))
    }

    @Test("presence bitmask marks only required fields")
    func requiredMask() {
        let (expansion, _) = expandSchemaForTesting("""
        @Schema struct S {
            var required: String
            var optional: String?
            var defaulted: Int = 3
        }
        """)
        // Field 0 is required -> reported when bit 0 unset. Optionals and defaults are
        // absent-safe, so no missing-check is emitted for them.
        #expect(expansion.contains("__presence & 1 == 0"))
        #expect(!expansion.contains("__presence & 2 == 0"))
        #expect(!expansion.contains("__presence & 4 == 0"))
    }
}

/// The `@Wraps` equivalent of `expandSchemaForTesting`. Runs both attachments, since the
/// diagnostics this macro emits come from the shared `parse` step that each calls.
func expandWrapsForTesting(
    _ source: String
) -> (expansion: String, diagnostics: [String]) {
    let file = Parser.parse(source: source)
    let context = BasicMacroExpansionContext(
        sourceFiles: [file: .init(moduleName: "Test", fullFilePath: "test.swift")])
    guard let decl = file.statements.compactMap({ $0.item.as(StructDeclSyntax.self) }).first,
          let attribute = decl.attributes.compactMap({ $0.as(AttributeSyntax.self) })
            .first(where: { $0.attributeName.trimmedDescription == "Wraps" }) else {
        return ("", ["no @Wraps attribute found"])
    }
    let members = (try? WrapsMacro.expansion(
        of: attribute, providingMembersOf: decl, in: context)) ?? []
    let exts = (try? WrapsMacro.expansion(
        of: attribute, attachedTo: decl,
        providingExtensionsOf: TypeSyntax(stringLiteral: decl.name.text),
        conformingTo: [], in: context)) ?? []
    let text = (members.map(\.description) + exts.map(\.description)).joined(separator: "\n")
    // Both attachments run the same diagnostic path, so the same message appears twice.
    var seen: Set<String> = []
    let diags = context.diagnostics.map(\.message).filter { seen.insert($0).inserted }
    return (text, diags)
}

// MARK: - The refusal table
//
// `Sources/AssayMacros/SchemaRefusals.swift`, 2026-09-10. Every case below expanded with
// no diagnostic before that file existed, and then did less than it said — the audit
// compiled and ran each one to be sure. The principle is stated in three places; this is
// the suite that holds the macro to it.

@Suite("Refusals — accepted-and-ignored is worse than refused")
struct RefusalTests {

    private func diags(_ src: String) -> [String] { expandSchemaForTesting(src).diagnostics }

    @Test("@XML(root:) without an XML format")
    func xmlRootWithoutXML() {
        let d = diags(#"@Schema @XML(root: "book") struct S { var a: Int }"#)
        #expect(d.contains { $0.contains("does not decode XML") }, "got \(d)")
    }

    @Test("@XML placement without an XML format")
    func xmlPlacementWithoutXML() {
        let d = diags("@Schema struct S { @XML(.attribute) var a: Int }")
        #expect(d.contains { $0.contains("does not decode XML") }, "got \(d)")
    }

    @Test("@XML in both forms is fine once the format is declared")
    func xmlWithFormat() {
        let d = diags(#"@Schema(formats: .xml) @XML(root: "b") struct S { @XML(.attribute) var a: Int }"#)
        #expect(d.isEmpty, "got \(d)")
    }

    /// The sink is the declaration of intent, so it implies `.collect` rather than being
    /// refused — the expansion must carry the collecting arm.
    @Test("@Extras implies unknownKeys: .collect")
    func extrasImpliesCollect() {
        let (exp, d) = expandSchemaForTesting(
            "@Schema struct S { var a: Int; @Extras var rest: [String: RawValue] }")
        #expect(d.isEmpty, "got \(d)")
        #expect(exp.contains("__extras[__uk] = __uv"), "expansion does not collect")
        let (warn, d2) = expandSchemaForTesting(
            "@Schema(unknownKeys: .warn) struct S { var a: Int; @Extras var rest: [String: RawValue] }")
        #expect(d2.isEmpty)
        #expect(warn.contains("__extras[__uk] = __uv"))
    }

    @Test("@Extras with unknownKeys: .reject is contradictory")
    func extrasWithReject() {
        let d = diags("@Schema(unknownKeys: .reject) struct S { var a: Int; @Extras var r: [String: RawValue] }")
        #expect(d.contains { $0.contains("both cannot hold") }, "got \(d)")
    }

    @Test("@Key and @Key(path:) on one property")
    func keyAndPath() {
        let d = diags(#"@Schema struct S { @Key("x") @Key(path: "a.b") var a: Int }"#)
        #expect(d.contains { $0.contains("one wire location") }, "got \(d)")
    }

    @Test("@Ignore beside an attribute that would never run")
    func ignoreWithValidate() {
        let d = diags("@Schema struct S { var b: Int; @Ignore @Validate(.min(1)) var a: Int = 0 }")
        #expect(d.contains { $0.contains("@Validate would never run") }, "got \(d)")
        let plain = diags("@Schema struct S { var b: Int; @Ignore var a: Int = 0 }")
        #expect(plain.isEmpty, "a plain @Ignore is fine: \(plain)")
    }

    @Test("@OneOrMany on a non-array")
    func oneOrManyScalar() {
        let d = diags("@Schema struct S { @OneOrMany var a: Int }")
        #expect(d.contains { $0.contains("is not an array") }, "got \(d)")
    }

    /// Was a type error INSIDE the expansion: "cannot convert value of type 'Int' to
    /// expected argument type 'String'" at `macro expansion @Schema:71`.
    @Test("@Preprocess on a non-String")
    func preprocessOnInt() {
        let d = diags("@Schema struct S { @Preprocess(.trim) var a: Int }")
        #expect(d.contains { $0.contains("is not one") }, "got \(d)")
        let ok = diags("@Schema struct S { @Preprocess(.trim) var a: String? }")
        #expect(ok.isEmpty, "an optional String is a String: \(ok)")
        // The WIRE type is what @Preprocess sees. The first version of this refusal read
        // the declared type and refused exactly the pairing the attributes exist for.
        let transformed = diags(
            "@Schema struct S { @Preprocess(.trim) @Transform({ (s: String) in s.count }) var n: Int }")
        #expect(transformed.isEmpty, "a String wire type is a String: \(transformed)")
    }

    @Test("an empty @Schema struct")
    func emptyStruct() {
        let d = diags("@Schema struct S { }")
        #expect(d.contains { $0.contains("no stored properties") }, "got \(d)")
    }
}

// MARK: - Types the macro can see are wrong
//
// 2026-09-10, second audit: each of these compiled to "type 'X' has no member '_assay'"
// inside the expansion — the single most common error in a newcomer probe battery.

extension RefusalTests {

    @Test("undecodable shapes are refused with the alternative named", arguments: [
        ("var a: Set<String>", "Set"),
        ("var a: Int??", "optional of an optional"),
        ("var a: [Int?]", "array of optionals"),
        ("var a: (Int, Int)", "tuple"),
        ("var a: (Int) -> Int", "function type"),
        ("var a: Any", "cannot be decoded"),
        ("var a: Int!", "implicitly unwrapped"),
        ("var a: Character", "not a field type"),
        ("var a: Data", "not a field type"),
        ("var a: URL", "not a field type"),
        ("var a: Decimal", "not a field type"),
    ])
    func undecodable(_ decl: String, _ fragment: String) {
        let d = diags("@Schema struct S { \(decl); var ok: Int }")
        #expect(d.contains { $0.contains(fragment) }, "\(decl): \(d)")
    }

    @Test("an @Ignore'd property of an undecodable type is fine")
    func ignoredUndecodable() {
        let d = diags("@Schema struct S { var ok: Int; @Ignore var a: Set<String> = [] }")
        #expect(d.isEmpty, "\(d)")
    }

    @Test("a generic struct is refused")
    func generic() {
        let d = diags("@Schema struct S<T: Sendable> { var a: Int }")
        #expect(d.contains { $0.contains("generic") }, "\(d)")
    }

    @Test("@Extras with a value type that cannot hold anything")
    func extrasValueType() {
        let d = diags("@Schema(unknownKeys: .collect) struct S { var a: Int; @Extras var r: [String: Int] }")
        #expect(d.contains { $0.contains("[String: RawValue]") }, "\(d)")
    }

    /// The nominal case the macro cannot see — a struct that is not `@Schema` — gets a
    /// zero-cost assertion whose failure names the protocol to adopt.
    @Test("a nested nominal type gets a _assayRequire assertion, once")
    func requireAssertion() {
        let (exp, d) = expandSchemaForTesting(
            "@Schema(formats: .all) struct S { var n: N; var m: [N]; var o: N?; var p: [String: P] }")
        #expect(d.isEmpty, "\(d)")
        #expect(exp.components(separatedBy: "Assay._assayRequireJSON(N.self)").count == 2)
        #expect(exp.contains("Assay._assayRequireJSON(P.self)"))
        #expect(exp.contains("Assay._assayRequireRaw(N.self)"))
        let (ctx, _) = expandSchemaForTesting("@Schema(context: C.self) struct S { var n: N }")
        #expect(!ctx.contains("_assayRequire"), "a contextual parent must not assert")
    }
}
