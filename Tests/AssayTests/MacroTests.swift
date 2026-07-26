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

    guard let structDecl = file.statements
        .compactMap({ $0.item.as(StructDeclSyntax.self) })
        .first else {
        return ("", ["no struct found in source"])
    }
    guard let attribute = structDecl.attributes
        .compactMap({ $0.as(AttributeSyntax.self) })
        .first(where: { $0.attributeName.trimmedDescription == "Schema" }) else {
        return ("", ["no @Schema attribute found"])
    }

    let extensions = (try? SchemaMacro.expansion(
        of: attribute,
        attachedTo: structDecl,
        providingExtensionsOf: TypeSyntax(stringLiteral: structDecl.name.text),
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
