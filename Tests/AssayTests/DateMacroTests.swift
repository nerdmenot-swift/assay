// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// @DateFormat's compile-time behaviour: the diagnostics are the feature, and the two
// pattern checkers (macro plugin and core runtime) are kept honest by a parity test —
// the checker is duplicated because the plugin cannot link the core, and duplicated
// logic drifts unless something fails when it does.
//===----------------------------------------------------------------------===//

import Testing
import SwiftSyntax
import SwiftParser
import SwiftSyntaxMacros
import SwiftSyntaxMacroExpansion
@testable import AssayMacros
@testable import AssayCore

/// Expand the @DateFormat peer macro on the first annotated property in `source`,
/// returning the diagnostics. Mirrors `expandSchemaForTesting`.
private func expandDateFormat(_ source: String) -> [String] {
    let file = Parser.parse(source: source)
    let context = BasicMacroExpansionContext(
        sourceFiles: [file: .init(moduleName: "Test", fullFilePath: "test.swift")])

    guard let structDecl = file.statements
        .compactMap({ $0.item.as(StructDeclSyntax.self) }).first else {
        return ["no struct found"]
    }
    for member in structDecl.memberBlock.members {
        guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
        for attr in varDecl.attributes.compactMap({ $0.as(AttributeSyntax.self) })
        where attr.attributeName.trimmedDescription == "DateFormat" {
            _ = try? DateFormatMacro.expansion(
                of: attr, providingPeersOf: DeclSyntax(varDecl), in: context)
            return context.diagnostics.map(\.message)
        }
    }
    return ["no @DateFormat attribute found"]
}

@Suite("@DateFormat diagnostics")
struct DateFormatMacroTests {

    @Test("a valid chain expands silently")
    func valid() {
        #expect(expandDateFormat("""
        struct S { @DateFormat(.iso8601, .unixMillis, .pattern("yyyy-MM-dd")) var d: Date }
        """).isEmpty)
    }

    @Test("on a non-Date property, the attribute is refused with the type named")
    func wrongType() {
        let diags = expandDateFormat("""
        struct S { @DateFormat(.iso8601) var d: String }
        """)
        #expect(diags.contains { $0.contains("Date properties") && $0.contains("String") })
    }

    @Test("[Date] and Date? are Date properties")
    func wrapperShapes() {
        #expect(expandDateFormat(
            "struct S { @DateFormat(.iso8601) var d: [Date] }").isEmpty)
        #expect(expandDateFormat(
            "struct S { @DateFormat(.iso8601) var d: Date? }").isEmpty)
    }

    @Test("zero formats is an error, not a silent no-op")
    func empty() {
        let diags = expandDateFormat("struct S { @DateFormat() var d: Date }")
        #expect(diags.contains { $0.contains("at least one format") })
    }

    @Test("an unknown format is named, with the supported list")
    func unknown() {
        let diags = expandDateFormat(
            "struct S { @DateFormat(.epochDays) var d: Date }")
        #expect(diags.contains { $0.contains("'epochDays'") && $0.contains(".rfc9110") })
    }

    @Test("a bad pattern fails at expansion with the runtime's own words")
    func badPattern() {
        let diags = expandDateFormat(
            #"struct S { @DateFormat(.pattern("EEE dd")) var d: Date }"#)
        #expect(diags.contains { $0.contains("'EEE'") })
        let missing = expandDateFormat(
            #"struct S { @DateFormat(.pattern("HH:mm")) var d: Date }"#)
        #expect(missing.contains { $0.contains("yyyy, MM and dd") })
    }

    @Test("a non-literal pattern cannot be checked, and says so")
    func nonLiteralPattern() {
        let diags = expandDateFormat(
            "struct S { @DateFormat(.pattern(someVariable)) var d: Date }")
        #expect(diags.contains { $0.contains("string literal") })
    }
}

@Suite("Pattern checker parity")
struct PatternParityTests {

    /// The macro's duplicated checker and the core's compiler must agree — same verdict,
    /// same words — or an attribute the macro accepted fails at runtime (or worse, the
    /// reverse). One list, both implementations, every case.
    @Test("both checkers give the same verdict and the same words", arguments: [
        "yyyy-MM-dd",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "dd/MM/yyyy HH:mm",
        "yyyyMMdd",
        "yyyy-MM-dd HH:mm:ss",
        "''yyyy-MM-dd''",
        "EEE, dd MMM yyyy",          // unsupported field
        "HH:mm",                     // no date
        "yyyy-MM",                   // no day
        "yyy-MM-dd",                 // wrong run length
        "yyyy-MM-dd'T",              // unterminated quote
        "",                          // nothing at all
    ])
    func parity(_ pattern: String) {
        let macroVerdict = checkDatePattern(pattern)
        let coreVerdict: String?
        switch DateParser.compilePattern(pattern) {
        case .success: coreVerdict = nil
        case .failure(let why): coreVerdict = why
        }
        #expect(macroVerdict == coreVerdict,
                "\"\(pattern)\": macro says \(macroVerdict ?? "ok"), core says \(coreVerdict ?? "ok")")
    }
}

@Suite("@Schema Date expansion shape")
struct DateExpansionShapeTests {

    @Test("a bare Date field uses the shared default formats, no per-field static")
    func bareDate() {
        let (expansion, diags) = expandSchemaForTesting(
            "@Schema struct S { var d: Date }")
        #expect(diags.isEmpty)
        #expect(expansion.contains("decodeDate"))
        #expect(expansion.contains("Assay.DateFormat.defaultFormats"))
        #expect(!expansion.contains("__assayDateFormats_"))
        #expect(expansion.contains("Date(timeIntervalSince1970:"))
    }

    @Test("@DateFormat emits one static candidate array, referenced by the decode line")
    func withFormats() {
        let (expansion, _) = expandSchemaForTesting("""
        @Schema struct S { @DateFormat(.iso8601, .unixSeconds) var d: Date }
        """)
        #expect(expansion.contains(
            "static let __assayDateFormats_0: [Assay.DateFormat] = [.iso8601, .unixSeconds]"))
        #expect(expansion.contains("Self.__assayDateFormats_0"))
    }

    @Test("date rules type-check at expansion: .before on Int is refused")
    func dateRuleOnInt() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S { @Validate(.before("2030-01-01")) var n: Int }
        """)
        #expect(diags.contains { $0.contains(".before") && $0.contains("Date") })
    }

    @Test("string rules on Date are refused the same way")
    func stringRuleOnDate() {
        let (_, diags) = expandSchemaForTesting("""
        @Schema struct S { @Validate(.email) var d: Date }
        """)
        #expect(diags.contains { $0.contains(".email") && $0.contains("String") })
    }

    @Test("validation on a Date field compares epoch seconds")
    func validationArgument() {
        let (expansion, _) = expandSchemaForTesting("""
        @Schema struct S { @Validate(.before("2030-01-01")) var d: Date }
        """)
        #expect(expansion.contains(".timeIntervalSince1970"))
    }
}
