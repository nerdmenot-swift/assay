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
    guard
        let attribute = decl.attributes
            .compactMap({ $0.as(AttributeSyntax.self) })
            .first(where: { $0.attributeName.trimmedDescription == "Schema" })
    else {
        return ("", ["no @Schema attribute found"])
    }

    let extensions =
        (try? SchemaMacro.expansion(
            of: attribute,
            attachedTo: decl,
            providingExtensionsOf: TypeSyntax(stringLiteral: structDeclName),
            conformingTo: [],
            in: context)) ?? []

    return (
        extensions.map(\.description).joined(separator: "\n"),
        context.diagnostics.map(\.message)
    )
}

@Suite("Macro diagnostics")
struct MacroDiagnosticTests {

    @Test("var x = 3 without a type annotation is a hard error, not a guess")
    func needsTypeAnnotation() {
        // A macro only sees source text — it cannot ask the type checker what `3` is,
        // and guessing Int would be wrong the moment someone writes `var timeout = 1.5`.
        let (_, diags) = expandSchemaForTesting(
            """
            @Schema struct S { var x = 3 }
            """)
        #expect(
            diags.contains {
                $0.contains("'x'") && $0.contains("explicit type annotation")
            })
    }

    @Test("let with an initializer cannot be decoded")
    func letWithInitializer() {
        let (_, diags) = expandSchemaForTesting(
            """
            @Schema struct S { let y: Int = 3
                var a: String }
            """)
        #expect(
            diags.contains {
                $0.contains("'let y'") && $0.contains("cannot be decoded")
            })
    }

    @Test("two properties reading the same wire key is an error")
    func duplicateKey() {
        let (_, diags) = expandSchemaForTesting(
            """
            @Schema struct S {
                @Key("id") var a: String
                @Key("id") var b: String
            }
            """)
        #expect(diags.contains { $0.contains("duplicate wire key \"id\"") })
    }

    @Test("aliases participate in duplicate detection too")
    func duplicateAlias() {
        let (_, diags) = expandSchemaForTesting(
            """
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
        let (_, diags) = expandSchemaForTesting(
            """
            @Schema(unknownKeys: .collect) struct S { var a: String }
            """)
        #expect(
            diags.contains {
                $0.contains("@Extras") && $0.contains("[String: RawValue]")
            })
    }

    @Test("@Extras must be a String-keyed dictionary")
    func extrasWrongType() {
        let (_, diags) = expandSchemaForTesting(
            """
            @Schema struct S {
                var a: String
                @Extras var rest: [Int: RawValue]
            }
            """)
        #expect(diags.contains { $0.contains("dictionary keyed by String") })
    }

    @Test("two @Extras properties is an error")
    func multipleExtras() {
        let (_, diags) = expandSchemaForTesting(
            """
            @Schema struct S {
                @Extras var a: [String: RawValue]
                @Extras var b: [String: RawValue]
            }
            """)
        #expect(diags.contains { $0.contains("only one @Extras") })
    }

    @Test("@Schema on a non-struct is refused")
    func notAStruct() {
        let (_, diags) = expandSchemaForTesting(
            """
            @Schema class C { var a: String }
            """)
        // A class parses as a class decl, so the helper reports no struct — but applying
        // the macro to an enum/class through the compiler surfaces the macro's own
        // diagnostic; assert the helper's failure mode here and the macro's directly.
        #expect(!diags.isEmpty)
    }

    @Test("a clean struct produces no diagnostics")
    func clean() {
        let (expansion, diags) = expandSchemaForTesting(
            """
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
        #expect(!expansion.contains("\"avatarUrl\""))  // the .convertFromSnakeCase bug
    }

    @Test("the window table is emitted sparse, never as a 256-element literal")
    func sparseTable() {
        // docs/COMPILE-TIME.md §3 rule 1: a 256-element array literal costs 16% of
        // expansion time in the type checker. The macro must never regress to it.
        let (expansion, _) = expandSchemaForTesting(
            """
            @Schema struct S { var alpha: String
                var beta: Int
                var gamma: Bool }
            """)
        #expect(expansion.contains("repeating:"))
        #expect(!expansion.contains(", 3, 3, 3, 3, 3, 3, 3, 3,"))
    }

    @Test("@Ignore excludes a field from decode but the init still receives defaults")
    func ignored() {
        let (expansion, _) = expandSchemaForTesting(
            """
            @Schema struct S { var a: String
                @Ignore var scratch: [String] = [] }
            """)
        #expect(!expansion.contains("scratch"))
    }

    @Test("static, computed and lazy members are skipped")
    func skippedMembers() {
        let (expansion, diags) = expandSchemaForTesting(
            """
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
        let (expansion, _) = expandSchemaForTesting(
            """
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
            .first(where: { $0.attributeName.trimmedDescription == "Wraps" })
    else {
        return ("", ["no @Wraps attribute found"])
    }
    let members =
        // The FOUR-argument requirement, which is the one `WrapsMacro` implements. This
        // called the three-argument form until 2026-10-04 and got `[]` back from it, behind
        // a `try?` — so the helper returned the extension and silently none of the members.
        // Observed in the first `wraps-*` goldens, which were eight lines long.
        (try? WrapsMacro.expansion(
            of: attribute, providingMembersOf: decl, conformingTo: [], in: context)) ?? []
    let exts =
        (try? WrapsMacro.expansion(
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
        let d = diags(
            #"@Schema(formats: .xml) @XML(root: "b") struct S { @XML(.attribute) var a: Int }"#)
        #expect(d.isEmpty, "got \(d)")
    }

    // WHERE THE CARET LANDS. Every refusal in this macro names the property — except the
    // three in `checkValidations`, which were attached to the `@Schema` node and so put the
    // caret on the type's first line whatever property was wrong. On a type with thirty
    // fields that is the difference between a fix and a search.
    //
    // `expandSchemaForTesting` returns messages, not positions, so the assertion here is
    // that the diagnostic is attached to the `@Validate` attribute node. The position is
    // checked end-to-end by compiling the case in a consumer package.

    @Test("a rule/type mismatch is attached to the @Validate attribute, not to @Schema")
    func ruleRefusalPointsAtTheAttribute() {
        let src = """
            @Schema struct S {
                var b: Int
                @Validate(.email) var a: Int
            }
            """
        let file = Parser.parse(source: src)
        let context = BasicMacroExpansionContext(
            sourceFiles: [file: .init(moduleName: "Test", fullFilePath: "test.swift")])
        let structDecl = file.statements.compactMap { $0.item.as(StructDeclSyntax.self) }.first!
        let attribute = structDecl.attributes.first!.as(AttributeSyntax.self)!
        _ = try? SchemaMacro.expansion(
            of: attribute,
            attachedTo: structDecl,
            providingExtensionsOf: TypeSyntax(stringLiteral: "S"),
            conformingTo: [], in: context)
        let d = context.diagnostics.first { $0.message.contains("applies to String") }
        // The node it points at is the attribute itself — `@Validate(.email)` — so its
        // description is the attribute source, not the whole struct.
        #expect(
            d?.node.trimmedDescription == "@Validate(.email)",
            "diagnostic is attached to: \(String(describing: d?.node.trimmedDescription))")
    }

    // FOUR COMBINATIONS THAT USED TO COMPILE AND DO NOTHING, found by the audit on
    // 2026-09-12. Each parsed, type-checked, and was silently dropped — which is the
    // failure mode this suite is named after. The fourth is the interesting one: its
    // diagnostic already existed and was correct, and ran only under `encodes: true`,
    // so a decode-only XML schema never saw it.

    @Test("@Key on an @Extras bag — the bag has no wire key of its own")
    func keyOnExtras() {
        let d = diags(
            """
            @Schema struct S { var a: Int
                @Key("bag") @Extras var rest: [String: RawValue] = [:] }
            """)
        #expect(d.contains { $0.contains("@Extras collects the keys") }, "got \(d)")
    }

    @Test("@Key(path:) beside @Inline — two answers for one location")
    func keyPathWithInline() {
        let d = diags(
            """
            @Schema struct S { @Schema struct In: Equatable { var a: String }
                @Key(path: "x.y") @Inline var inner: In }
            """)
        #expect(d.contains { $0.contains("@Inline splices") }, "got \(d)")
    }

    @Test("@Coerce on something that is not a coercible scalar")
    func coerceOnNonScalar() {
        let d = diags(
            """
            @Schema struct S { @Schema struct In: Equatable { var a: String }
                @Coerce var inner: In }
            """)
        #expect(d.contains { $0.contains("@Coerce accepts a scalar") }, "got \(d)")
    }

    @Test("@Coerce on a scalar, and through a @Transform's WIRE type, still compiles")
    func coerceStillLegal() {
        #expect(diags("@Schema struct S { @Coerce var port: Int }").isEmpty)
        // The declared type is String and the wire type is Int; the wire type is the one
        // that coerces, so reading the declared type here would refuse the exact pairing
        // the two attributes exist for.
        #expect(
            diags(
                """
                @Schema struct S { @Coerce @Transform({ (s: Int) in String(s) }) var port: String }
                """
            ).isEmpty)
    }

    @Test("@XML(.attribute) on an array is refused when DECODING, not only when encoding")
    func xmlAttributeOnArrayDecodeOnly() {
        let d = diags("@Schema(formats: .xml) struct S { @XML(.attribute) var tags: [String] }")
        #expect(d.contains { $0.contains("applies to scalar fields") }, "got \(d)")
        // And it still fires on the encoding side, which is where it always did.
        let e = diags(
            """
            @Schema(formats: .xml, encodes: true) struct S { @XML(.attribute) var tags: [String] }
            """)
        #expect(e.contains { $0.contains("applies to scalar fields") }, "got \(e)")
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
            "@Schema(unknownKeys: .warn) struct S { var a: Int; @Extras var rest: [String: RawValue] }"
        )
        #expect(d2.isEmpty)
        #expect(warn.contains("__extras[__uk] = __uv"))
    }

    @Test("@Extras with unknownKeys: .reject is contradictory")
    func extrasWithReject() {
        let d = diags(
            "@Schema(unknownKeys: .reject) struct S { var a: Int; @Extras var r: [String: RawValue] }"
        )
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
            "@Schema struct S { @Preprocess(.trim) @Transform({ (s: String) in s.count }) var n: Int }"
        )
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

    @Test(
        "undecodable shapes are refused with the alternative named",
        arguments: [
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
            ("var a: Decimal", "not a field type")
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
        let d = diags(
            "@Schema(unknownKeys: .collect) struct S { var a: Int; @Extras var r: [String: Int] }")
        #expect(d.contains { $0.contains("[String: RawValue]") }, "\(d)")
    }

    /// The nominal case the macro cannot see — a struct that is not `@Schema` — gets a
    /// zero-cost assertion whose failure names the protocol to adopt.
    @Test("a nested nominal type gets a _assayRequire assertion, once")
    func requireAssertion() {
        let (exp, d) = expandSchemaForTesting(
            "@Schema(formats: .all) struct S { var n: N; var m: [N]; var o: N?; var p: [String: P] }"
        )
        #expect(d.isEmpty, "\(d)")
        #expect(exp.components(separatedBy: "Assay._assayRequireJSON(N.self)").count == 2)
        #expect(exp.contains("Assay._assayRequireJSON(P.self)"))
        #expect(exp.contains("Assay._assayRequireRaw(N.self)"))
        let (ctx, _) = expandSchemaForTesting("@Schema(context: C.self) struct S { var n: N }")
        #expect(!ctx.contains("_assayRequire"), "a contextual parent must not assert")
    }
}

// MARK: - @Check shapes, and an empty key

extension RefusalTests {

    @Test("a field check whose parameter type is not the field's")
    func checkParamType() {
        let d = diags(
            #"@Schema struct S { var a: Int; @Check(\S.a) static func f(_ a: String) -> String? { nil } }"#
        )
        #expect(d.contains { $0.contains("declares its parameter as 'String'") }, "\(d)")
    }

    @Test("a cross-field check with the wrong shape")
    func crossShape() {
        let d = diags(
            #"@Schema struct S { var a: Int; @Check static func f(_ v: S) -> String? { nil } }"#)
        #expect(d.contains { $0.contains("inout Issues<S>") }, "\(d)")
        let ok = diags(
            #"@Schema struct S { var a: Int; @Check static func f(_ v: S, _ i: inout Issues<S>) {} }"#
        )
        #expect(ok.isEmpty, "\(ok)")
    }

    @Test("a key path to a property the type does not declare")
    func checkUnknownField() {
        let d = diags(
            #"@Schema struct S { var a: Int; @Check(\S.b) static func f(_ b: Int) -> String? { nil } }"#
        )
        #expect(d.contains { $0.contains("does not declare") && $0.contains("'a'") }, "\(d)")
    }

    @Test("@Key with an empty name")
    func emptyKey() {
        let d = diags(#"@Schema struct S { @Key("") var a: Int }"#)
        #expect(d.contains { $0.contains("empty wire key") }, "\(d)")
    }
}

// MARK: - Refusals nothing had triggered
//
// Each diagnostic below existed and had never been produced by a test. A refusal is a
// feature with a message; an untested one is a message nobody has read. The table form is
// deliberate: source, and a phrase the message must contain.

@Suite("Refusals: the rest of the table")
struct RefusalCoverageTests {

    @Test(
        "a rule on the wrong kind of field names the kind it wanted",
        arguments: [
            // String field
            ("@Validate(.unique) var a: String", "applies to an Array"),
            ("@Validate(.positive) var a: String", "applies to a number"),
            // number field
            ("@Validate(.unique) var a: Int", "applies to an Array"),
            ("@Validate(.notEmpty) var a: Double", "applies to an Array"),
            // array field
            ("@Validate(.email) var a: [String]", "applies to String"),
            ("@Validate(.positive) var a: [Int]", "applies to a number"),
            // Date field
            ("@Validate(.email) var a: Date", "applies to String"),
            ("@Validate(.positive) var a: Date", "applies to a number"),
            ("@Validate(.min(1)) var a: Date", "applies to a number"),
            ("@Validate(.unique) var a: Date", "applies to an Array"),
            // a date rule anywhere else
            ("@Validate(.before(\"2030-01-01\")) var a: String", "applies to Date"),
            // Bool, and a nested type the macro knows nothing about
            ("@Validate(.email) var a: Bool", "applies to String"),
            ("@Validate(.positive) var a: Bool", "applies to a number"),
            ("@Validate(.min(1)) var a: Bool", "applies to String, a number, or an Array"),
            ("@Validate(.notEmpty) var a: Nested", "applies to String, a number, or an Array"),
            // element types with no typed overload
            (
                "@Validate(.each(.min(1))) var a: [Bool]",
                "supports elements of String, Int or Double"
            ),
            ("@Validate(.unique) var a: [Nested]", "supports elements of String, Int or Double")
        ])
    func ruleCategory(field: String, phrase: String) {
        let d = expandSchemaForTesting("@Schema struct S { \(field) }").diagnostics
        #expect(d.count == 1, "\(field): \(d)")
        #expect(d.first?.contains(phrase) == true, "\(field): \(d)")
        #expect(d.first?.contains("'a' is declared") == true, "\(field): \(d)")
    }

    @Test(
        "malformed attributes are refused where they are written",
        arguments: [
            (
                "@Schema struct S { var a: Int; @Check func f(_ v: S, _ i: inout Issues<S>) {} }",
                "@Check function 'f' must be static"
            ),
            (
                "@Schema struct S { var a: Int; @Check(\\S.a) static func f() -> String? { nil } }",
                "'f' declares 0 parameters"
            ),
            (
                """
                @Schema(context: C.self) struct S { var a: Int
                @Check(\\S.a) static func f(_ v: Int) -> String? { nil } }
                """,
                "and the context"
            ),
            (
                "@Schema struct S { @Transform(convert) var a: Int }",
                "@Transform takes a closure with a typed parameter"
            ),
            (
                "@Schema struct S { @Transform({ a in a }) var a: Int }",
                "closure parameter needs a type annotation"
            ),
            (
                "@Schema(discriminator: \"type\") enum E {}",
                "needs at least one case"
            )
        ])
    func malformed(source: String, phrase: String) {
        let d = expandSchemaForTesting(source).diagnostics
        #expect(d.contains { $0.contains(phrase) }, "\(source): \(d)")
    }

    @Test("@Wraps with no arguments says what it needs")
    func wrapsNeedsAType() {
        let d = expandWrapsForTesting("@Wraps struct S {}").diagnostics
        #expect(d == ["@Wraps needs the wrapped type: @Wraps(String.self, .email)"])
    }

    @Test("computed properties are not fields, however they are spelled")
    func computedProperties() {
        let (expansion, d) = expandSchemaForTesting(
            """
            @Schema struct S {
                var a: Int
                var twice: Int { a * 2 }
                var thrice: Int { get { a * 3 } }
                var watched: Int { didSet {} }
            }
            """)
        #expect(d.isEmpty, "\(d)")
        // Observers keep a property stored; a getter does not.
        #expect(expansion.contains("\"watched\""))
        #expect(!expansion.contains("\"twice\"") && !expansion.contains("\"thrice\""))
    }

    @Test("Optional<T> and a backticked name are read as T? and the bare name")
    func spellings() {
        let (expansion, d) = expandSchemaForTesting(
            "@Schema struct S { var a: Optional<Int>; var `default`: String }")
        #expect(d.isEmpty, "\(d)")
        #expect(expansion.contains("_decodeIntOrNull"))
        #expect(expansion.contains("\"default\""))
        #expect(!expansion.contains("\"`default`\""))
    }

    @Test("declarations the macro steps over rather than treating as fields")
    func steppedOver() {
        // A method inside an @Inline'd struct is not a field and not an error.
        let (expansion, d) = expandSchemaForTesting(
            """
            @Schema struct S {
                struct P { var x: Int; func helper() {} }
                @Inline var p: P
                var a: Int
            }
            """)
        #expect(d.isEmpty, "\(d)")
        #expect(expansion.contains("\"x\"") && expansion.contains("\"a\""))
        #expect(!expansion.contains("helper"))

        // A tuple binding IS an error, and says what to write instead.
        let tuple = expandSchemaForTesting("@Schema struct S { var (b, c): (Int, Int) }")
        #expect(tuple.diagnostics.first?.contains("is a tuple") == true)
    }

    @Test("a described date with a text format is a string; with a unix one, a number")
    func describedDateFormats() {
        let (expansion, d) = expandSchemaForTesting(
            """
            @Schema(describes: true) struct S {
                @DateFormat(.rfc9110) var a: Date
                @DateFormat(.unixMillis) var b: Date
            }
            """)
        #expect(d.isEmpty, "\(d)")
        #expect(expansion.contains(".date(numeric: false)"))
        #expect(expansion.contains(".date(numeric: true)"))
    }

    @Test("a field check written with a rootless key path still names its field")
    func rootlessKeyPath() {
        // `\.a` does not compile in a real attribute (there is no Root to infer), but the
        // macro reads tokens, and reading this one as field `a` is what lets it report the
        // type mismatch below instead of "no such field".
        let d = expandSchemaForTesting(
            "@Schema struct S { var a: Int; @Check(\\.a) static func f(_ v: String) -> String? { nil } }"
        ).diagnostics
        #expect(d.count == 1, "\(d)")
        #expect(d.first?.contains("a") == true)
    }

    @Test("@Schema on an enum with no @Unknown case and no discriminator")
    func plainEnum() {
        let d = expandSchemaForTesting("@Schema enum E { case a, b }").diagnostics
        #expect(d.contains { $0.contains("@Unknown") }, "\(d)")
    }

    @Test("describes: true on a type that holds itself is refused, at any nesting")
    func recursiveDescribe() {
        for field in ["var next: Node?", "var children: [Node]", "var byName: [String: [Node]]"] {
            let d = expandSchemaForTesting(
                "@Schema(describes: true) struct Node { var name: String; \(field) }"
            ).diagnostics
            #expect(d.count == 1, "\(field): \(d)")
            #expect(d.first?.contains("holds 'Node' itself") == true, "\(field): \(d)")
        }
        // Without `describes:` a recursive type is fine, and so is a described type that
        // merely mentions another.
        #expect(
            expandSchemaForTesting("@Schema struct Node { var children: [Node] }")
                .diagnostics.isEmpty)
        #expect(
            expandSchemaForTesting("@Schema(describes: true) struct A { var b: [B] }")
                .diagnostics.isEmpty)
    }

    @Test("two key paths that cannot both be read are refused")
    func pathCollision() {
        // One key cannot be a value and an object at once — at any depth, in either order.
        for fields in [
            #"@Key(path: "a.b") var x: Int; @Key(path: "a.b.c") var y: Int"#,
            #"@Key(path: "a.b.c") var y: Int; @Key(path: "a.b") var x: Int"#
        ] {
            let d = expandSchemaForTesting("@Schema struct S { \(fields) }").diagnostics
            #expect(d.count == 1, "\(d)")
            #expect(d.first?.contains("one key cannot be both") == true, "\(d)")
            #expect(d.first?.contains("'x' reads \"a.b\" as a value") == true, "\(d)")
        }
        let same = expandSchemaForTesting(
            #"@Schema struct S { @Key(path: "a.b") var x: Int; @Key(path: "a.b") var y: Int }"#
        ).diagnostics
        #expect(same.first?.contains("both read the path \"a.b\"") == true, "\(same)")

        // Siblings and cousins are not collisions.
        let fine = expandSchemaForTesting(
            #"@Schema struct S { @Key(path: "a.b") var x: Int; @Key(path: "a.c.d") var y: Int; @Key(path: "a.c.e") var z: Int }"#
        ).diagnostics
        #expect(fine.isEmpty, "\(fine)")
    }
}
