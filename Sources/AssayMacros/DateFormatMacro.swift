// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// @DateFormat — a marker macro with teeth.
//
// Like @Key it expands to nothing and @Schema reads it off the member syntax. Unlike
// @Key, its arguments have failure modes worth catching at compile time, and every one
// of them gets a purpose-written diagnostic HERE, where the caret lands on the
// attribute — not a type error inside generated code the user has never seen:
//
//   * @DateFormat on a non-Date property (formats mean nothing there);
//   * an empty format list (variadics accept zero; zero formats decode nothing);
//   * a `.pattern` whose string is not a literal (a runtime value cannot be checked
//     at expansion, and unchecked patterns are how DateFormatter bugs happen);
//   * a `.pattern` literal that does not compile — checked with the SAME rules the
//     runtime uses, worded identically. The checker is deliberately duplicated from
//     AssayCore/Dates.swift (the plugin cannot link the core), and a parity test in
//     MacroTests keeps the two from drifting.
//===----------------------------------------------------------------------===//

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

public struct DateFormatMacro: PeerMacro {

    static let knownFormats: Set<String> = [
        "iso8601", "unixSeconds", "unixMillis", "rfc9110",
    ]

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {

        // Placement: the property must actually be a Date.
        if let varDecl = declaration.as(VariableDeclSyntax.self),
           let annotation = varDecl.bindings.first?.typeAnnotation {
            let t = annotation.type.trimmedDescription
            // No Foundation in the macro target; strip array/optional sigils by hand.
            let base = String(t.unicodeScalars.filter { $0 != "[" && $0 != "]" && $0 != "?" && $0 != " " })
            if base != "Date" && base != "Foundation.Date" {
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: SimpleDiagnostic(
                        "@DateFormat applies to Date properties; '\(t)' is not one")))
                return []
            }
        }

        guard let args = node.arguments?.as(LabeledExprListSyntax.self), !args.isEmpty else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: SimpleDiagnostic(
                    "@DateFormat needs at least one format — .iso8601, .unixSeconds, "
                    + ".unixMillis, .rfc9110, or .pattern(\"...\")")))
            return []
        }

        for arg in args {
            check(arg.expression, node: node, context: context)
        }
        return []
    }

    static func check(
        _ expr: ExprSyntax, node: AttributeSyntax, context: some MacroExpansionContext
    ) {
        // `.pattern("...")` — a call whose argument must be a checkable literal.
        if let call = expr.as(FunctionCallExprSyntax.self) {
            let callee = call.calledExpression.trimmedDescription
            guard callee.hasSuffix("pattern") else {
                unknown(callee, node: node, context: context)
                return
            }
            guard let first = call.arguments.first,
                  let literal = first.expression.as(StringLiteralExprSyntax.self),
                  literal.segments.allSatisfy({ $0.is(StringSegmentSyntax.self) }) else {
                context.diagnose(Diagnostic(
                    node: Syntax(expr),
                    message: SimpleDiagnostic(
                        ".pattern needs a string literal, so the pattern can be checked "
                        + "at compile time")))
                return
            }
            if let why = checkDatePattern(literal.segments.description) {
                context.diagnose(Diagnostic(
                    node: Syntax(expr), message: SimpleDiagnostic(why)))
            }
            return
        }

        // `.iso8601` and friends — a member access whose base name must be known.
        var name = expr.trimmedDescription
        if let dot = name.lastIndex(of: ".") {
            name = String(name[name.index(after: dot)...])
        }
        if !knownFormats.contains(name) {
            unknown(name, node: node, context: context)
        }
    }

    static func unknown(
        _ name: String, node: AttributeSyntax, context: some MacroExpansionContext
    ) {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: SimpleDiagnostic(
                "'\(name)' is not a date format; supported: .iso8601, .unixSeconds, "
                + ".unixMillis, .rfc9110, .pattern(\"...\")")))
    }
}

// MARK: - The pattern checker, duplicated from AssayCore/Dates.swift

/// Mirrors `DateParser.compilePattern`'s validation, wording included. The plugin
/// binary cannot link AssayCore, so the rules live twice; the parity test in MacroTests
/// runs both over the same inputs and fails if they disagree.
func checkDatePattern(_ pattern: String) -> String? {
    var sawYear = false, sawMonth = false, sawDay = false
    let bytes = Array(pattern.utf8)
    var i = 0
    while i < bytes.count {
        let c = bytes[i]
        if c == 0x27 {                             // ' — quoted literal
            i += 1
            if i < bytes.count, bytes[i] == 0x27 { i += 1; continue }
            var closed = false
            while i < bytes.count {
                if bytes[i] == 0x27 { closed = true; i += 1; break }
                i += 1
            }
            if !closed { return "unterminated quote in date pattern" }
            continue
        }
        let isLetter = (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A
        if !isLetter { i += 1; continue }
        var run = 1
        while i + run < bytes.count, bytes[i + run] == c { run += 1 }
        switch (Character(UnicodeScalar(c)), run) {
        case ("y", 4): sawYear = true
        case ("M", 2): sawMonth = true
        case ("d", 2): sawDay = true
        case ("H", 2), ("m", 2), ("s", 2), ("S", 3), ("Z", 1): break
        default:
            let field = String(repeating: String(UnicodeScalar(c)), count: run)
            return "unsupported pattern field '\(field)'; supported fields are "
                + "yyyy MM dd HH mm ss SSS Z, plus non-letter literals"
        }
        i += run
    }
    if !(sawYear && sawMonth && sawDay) {
        return "a date pattern needs at least yyyy, MM and dd to name an instant"
    }
    return nil
}
