// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// @Check, @Preprocess, @Transform, @Fallback — the macro half.
//
// Ordering, fixed and total (EXPERIENCE.md §11):
//   preprocess → coerce → decode → field rules → cross-field checks → transform
//
// @Check has a hard limit worth restating: an attached macro only receives the members
// declared in the type's own body, so a @Check in an extension is PERMANENTLY invisible
// to @Schema. The @Check marker macro detects that placement via lexicalContext and
// makes it a compile error rather than a silent, maddening no-op (EXPERIENCE.md §10).
//===----------------------------------------------------------------------===//

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

/// A `@Check` member found in the type body.
struct CheckDecl {
    var functionName: String
    /// For the field form `@Check(\.workEmail)`: the property the issue lands on.
    var fieldIdentifier: String?
    var isAsync: Bool
}

extension SchemaMacro {

    /// Collect `@Check` and `@AsyncCheck` members from the type body.
    static func checks(
        in structDecl: StructDeclSyntax,
        context: some MacroExpansionContext
    ) -> [CheckDecl] {
        var out: [CheckDecl] = []
        for member in structDecl.memberBlock.members {
            guard let fn = member.decl.as(FunctionDeclSyntax.self) else { continue }
            let attrs = fn.attributes.compactMap { $0.as(AttributeSyntax.self) }
            guard let checkAttr = attrs.first(where: {
                let n = $0.attributeName.trimmedDescription
                return n == "Check" || n == "AsyncCheck"
            }) else { continue }

            let isAsync = checkAttr.attributeName.trimmedDescription == "AsyncCheck"

            guard fn.modifiers.contains(where: { $0.name.text == "static" }) else {
                context.diagnose(Diagnostic(node: Syntax(fn), message: SimpleDiagnostic(
                    "@Check function '\(fn.name.text)' must be static")))
                continue
            }

            // Field form: @Check(\.workEmail)
            var field: String?
            if let args = checkAttr.arguments?.as(LabeledExprListSyntax.self),
               let first = args.first {
                let text = first.expression.trimmedDescription
                if text.hasPrefix("\\.") {
                    field = String(text.dropFirst(2))
                } else if text.hasPrefix("\\") , let dot = text.firstIndex(of: ".") {
                    field = String(text[text.index(after: dot)...])
                }
            }

            out.append(CheckDecl(functionName: fn.name.text,
                                 fieldIdentifier: field,
                                 isAsync: isAsync))
        }
        return out
    }

    /// The keypath→wire-key table cross-field checks resolve `at: \.field` against.
    static func fieldNameTable(_ typeName: String, _ fields: [SchemaField]) -> String {
        guard !fields.isEmpty else { return "" }
        let entries = fields
            .map { "\\.\($0.identifier): \"\($0.wireKey)\"" }
            .joined(separator: ", ")
        // PartialKeyPath is not Sendable; the table is immutable, so unsafe is honest.
        return """
        nonisolated(unsafe) static let __assayFieldNames: [PartialKeyPath<\(typeName)>: String] = [\(entries)]

        """
    }

    /// The post-construction check calls. `spans` gates caret capture for field checks.
    static func checkCalls(
        _ typeName: String,
        _ checks: [CheckDecl],
        _ fields: [SchemaField],
        spans: Bool
    ) -> String {
        let sync = checks.filter { !$0.isAsync }
        guard !sync.isEmpty else { return "" }

        var indexOf: [String: Int] = [:]
        for (i, f) in fields.enumerated() { indexOf[f.identifier] = i }

        var out = ""
        for check in sync {
            if let field = check.fieldIdentifier {
                // Field form: static func f(_ x: FieldType) -> String?
                let wire = fields.first { $0.identifier == field }?.wireKey ?? field
                let span = spans, idx = indexOf[field]
                let spanExpr = (span && idx != nil && fields[idx!].needsSpan)
                    ? "__sp\(idx!)" : "nil"
                out += """
                    if let __m = Self.\(check.functionName)(__result.\(field)) {
                        sink.add(Assay.Issue(code: .custom(__m),
                                             path: path + [.key("\(wire)")],
                                             location: \(spanExpr)))
                    }

                """
            } else {
                // Cross-field form: static func f(_ v: T, _ issues: inout Issues<T>)
                out += """
                    var __ck_\(check.functionName) = Assay.Issues<\(typeName)>(names: Self.__assayFieldNames)
                    Self.\(check.functionName)(__result, &__ck_\(check.functionName))
                    __ck_\(check.functionName).merge(into: &sink, at: path)

                """
            }
        }
        return out
    }

    /// The async-check runner, emitted only when @AsyncCheck members exist. Sync work
    /// runs first and collects everything; async checks run only if the sync pass was
    /// clean, and then concurrently (EXPERIENCE.md §10's ordering, stated precisely).
    static func asyncCheckRunner(_ typeName: String, _ checks: [CheckDecl]) -> String {
        let asyncs = checks.filter(\.isAsync)
        guard !asyncs.isEmpty else { return "" }

        let tasks = asyncs.map { check in
            """
                    group.addTask {
                        var __i = Assay.Issues<\(typeName)>(names: Self.__assayFieldNames)
                        await Self.\(check.functionName)(__value, &__i)
                        return __i
                    }
            """
        }.joined(separator: "\n")

        return """


        nonisolated public static func _assayAsyncChecks(
            _ __value: \(typeName),
            at path: [Assay.PathComponent]
        ) async -> [Assay.Issue] {
            await withTaskGroup(of: Assay.Issues<\(typeName)>.self) { group in
        \(tasks)
                var __sink = Assay.IssueSink()
                for await __i in group { __i.merge(into: &__sink, at: path) }
                return __sink.issues
            }
        }
        """
    }

    // MARK: @Preprocess / @Transform / @Fallback parsing

    static func preprocessOps(from attributes: [AttributeSyntax]) -> [String] {
        for attr in attributes where attr.attributeName.trimmedDescription == "Preprocess" {
            guard let args = attr.arguments?.as(LabeledExprListSyntax.self) else { continue }
            return args.map { $0.expression.trimmedDescription }
        }
        return []
    }

    /// `@Transform { (a: [String]) in Set(a) }` — the closure's parameter type IS the
    /// wire type; the declared property type is the output. The macro reads the parameter
    /// annotation syntactically, which is why the typed-closure spelling is required:
    /// a bare `{ Set($0) }` gives the macro nothing to decode by.
    static func transform(
        from attributes: [AttributeSyntax],
        context: some MacroExpansionContext
    ) -> (closure: String, wireType: String)? {
        for attr in attributes where attr.attributeName.trimmedDescription == "Transform" {
            // Attributes have no trailing closures; the closure is the single argument.
            guard let args = attr.arguments?.as(LabeledExprListSyntax.self),
                  let closure = args.first?.expression.as(ClosureExprSyntax.self) else {
                context.diagnose(Diagnostic(node: Syntax(attr), message: SimpleDiagnostic(
                    "@Transform takes a closure with a typed parameter, e.g. ({ (a: [String]) in Set(a) })")))
                return nil
            }
            guard let sig = closure.signature,
                  let clause = sig.parameterClause?.as(ClosureParameterClauseSyntax.self),
                  let first = clause.parameters.first,
                  let type = first.type?.trimmedDescription else {
                context.diagnose(Diagnostic(node: Syntax(attr), message: SimpleDiagnostic(
                    "@Transform's closure parameter needs a type annotation — the wire type the value arrives as, e.g. ({ (a: [String]) in Set(a) })")))
                return nil
            }
            return (closure.trimmedDescription, type)
        }
        return nil
    }

    static func fallbackExpr(from attributes: [AttributeSyntax]) -> String? {
        for attr in attributes where attr.attributeName.trimmedDescription == "Fallback" {
            guard let args = attr.arguments?.as(LabeledExprListSyntax.self),
                  let first = args.first else { continue }
            return first.expression.trimmedDescription
        }
        return nil
    }
}
