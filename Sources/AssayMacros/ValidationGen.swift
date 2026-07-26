//===----------------------------------------------------------------------===//
// @Validate — the macro half.
//
// The macro sees both the rule text and the declared field type, which is what lets a
// non-generic Rule be type-safe anyway: `@Validate(.email) var age: Int` is caught at
// expansion with a purpose-written diagnostic —
//
//     rule '.email' applies to String, but 'age' is declared Int
//
// — which is a considerably kinder message than anything a generic constraint failure
// would have produced (EXPERIENCE.md §5).
//
// Codegen discipline (docs/COMPILE-TIME.md §3): per validated field the macro emits ONE
// `static let` rule array (built once, zero per-decode cost) and ONE call per attribute
// into an `@inlinable` runtime overload. Rule logic never appears inline in a body.
//===----------------------------------------------------------------------===//

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

/// One parsed `@Validate(...)` attribute on a field.
struct ValidationAttr {
    /// Rule expressions, verbatim source text, re-emitted inside a `[Assay.Rule]` literal
    /// where leading-dot syntax resolves them. Opaque compositions (`.companySlug`) pass
    /// through untouched — that is the payoff of Rule being non-generic.
    var ruleExprs: [String]
    /// The callee names the macro could identify, for type checking. Parallel to
    /// `ruleExprs` where identifiable; opaque entries are absent.
    var ruleNames: [String]
    /// Attribute-level message override from a bare string literal.
    var override: String?
}

enum RuleTypeCheck {

    /// Which declared types each named rule applies to.
    static let stringOnly: Set<String> = [
        "length", "regex", "email", "url", "uuid", "hostname", "ascii",
        "trimmed", "lowercased", "prefix", "suffix", "contains", "oneOf",
    ]
    static let numberOnly: Set<String> = [
        "range", "positive", "negative", "nonNegative", "multipleOf", "finite",
    ]
    static let arrayOnly: Set<String> = ["count", "unique", "each"]
    /// Length on String, count on Array, magnitude on a number.
    static let polymorphic: Set<String> = ["min", "max"]
    /// String or Array.
    static let emptiness: Set<String> = ["notEmpty"]

    enum FieldCategory {
        case string, integer, floating, array(element: String), bool, other(String)

        init(_ baseType: String) {
            switch baseType {
            case "String": self = .string
            case "Int", "Int64", "Int32", "UInt": self = .integer
            case "Double", "Float": self = .floating
            case "Bool": self = .bool
            default:
                if baseType.hasPrefix("["), baseType.hasSuffix("]"),
                   !baseType.contains(":") {
                    self = .array(element: String(baseType.dropFirst().dropLast()))
                } else {
                    self = .other(baseType)
                }
            }
        }

        var displayName: String {
            switch self {
            case .string: return "String"
            case .integer, .floating: return "a number"
            case .array: return "an Array"
            case .bool: return "Bool"
            case .other(let t): return t
            }
        }
    }

    /// Nil when the rule applies; otherwise the category name it wanted.
    static func expectedCategory(rule: String, on category: FieldCategory) -> String? {
        switch category {
        case .string:
            if stringOnly.contains(rule) || polymorphic.contains(rule)
                || emptiness.contains(rule) { return nil }
            if numberOnly.contains(rule) { return "a number" }
            if arrayOnly.contains(rule) { return "an Array" }
        case .integer, .floating:
            if numberOnly.contains(rule) || polymorphic.contains(rule) { return nil }
            if stringOnly.contains(rule) { return "String" }
            if arrayOnly.contains(rule) || emptiness.contains(rule) { return "an Array" }
        case .array:
            if arrayOnly.contains(rule) || polymorphic.contains(rule)
                || emptiness.contains(rule) { return nil }
            if stringOnly.contains(rule) { return "String" }
            if numberOnly.contains(rule) { return "a number" }
        case .bool, .other:
            if stringOnly.contains(rule) { return "String" }
            if numberOnly.contains(rule) { return "a number" }
            if arrayOnly.contains(rule) || emptiness.contains(rule)
                || polymorphic.contains(rule) { return "String, a number, or an Array" }
        }
        return nil    // unknown name: an opaque composed rule — checked at runtime shape
    }
}

extension SchemaMacro {

    /// Parse the `@Validate` attributes off a member's attribute list.
    static func validations(
        from attributes: [AttributeSyntax]
    ) -> [ValidationAttr] {
        var out: [ValidationAttr] = []
        for attr in attributes where attr.attributeName.trimmedDescription == "Validate" {
            guard let args = attr.arguments?.as(LabeledExprListSyntax.self) else { continue }
            var parsed = ValidationAttr(ruleExprs: [], ruleNames: [], override: nil)
            for arg in args where arg.label == nil {
                if let literal = arg.expression.as(StringLiteralExprSyntax.self) {
                    // The message-as-a-rule trick: a bare literal overrides the message
                    // for every other rule in this attribute.
                    parsed.override = literal.segments.description
                    continue
                }
                parsed.ruleExprs.append(arg.expression.trimmedDescription)
                if let name = ruleName(of: arg.expression) {
                    parsed.ruleNames.append(name)
                }
            }
            out.append(parsed)
        }
        return out
    }

    /// `.min(3)` → "min", `.email` → "email", `Rule.companySlug` → "companySlug".
    static func ruleName(of expr: ExprSyntax) -> String? {
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return call.calledExpression.as(MemberAccessExprSyntax.self)?
                .declName.baseName.text
        }
        return expr.as(MemberAccessExprSyntax.self)?.declName.baseName.text
    }

    /// Expansion-time type checking, with EXPERIENCE.md §5's exact diagnostic shape.
    static func checkValidations(
        _ fields: [SchemaField],
        node: AttributeSyntax,
        context: some MacroExpansionContext
    ) -> Bool {
        var ok = true
        for f in fields {
            let category = RuleTypeCheck.FieldCategory(stripOptional(f.typeName))
            for attr in f.validations {
                if attr.ruleExprs.isEmpty, attr.override != nil {
                    context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                        "@Validate(\"\(attr.override!)\") has a message but no rule; a lone message does nothing")))
                    ok = false
                }
                for name in attr.ruleNames {
                    if let wanted = RuleTypeCheck.expectedCategory(rule: name, on: category) {
                        context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                            "rule '.\(name)' applies to \(wanted), but '\(f.identifier)' is declared \(f.typeName)")))
                        ok = false
                    }
                    // `.unique`/`.each` need a typed overload for the element.
                    if name == "unique" || name == "each",
                       case .array(let element) = category,
                       !["String", "Int", "Double"].contains(element) {
                        context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                            "rule '.\(name)' supports elements of String, Int or Double, but '\(f.identifier)' is declared \(f.typeName)")))
                        ok = false
                    }
                }
            }
        }
        return ok
    }

    /// The `static let` rule arrays, emitted once, shared by both decode bodies.
    static func ruleArrays(_ fields: [SchemaField]) -> String {
        var out = ""
        for (i, f) in fields.enumerated() {
            for (j, attr) in f.validations.enumerated() where !attr.ruleExprs.isEmpty {
                out += """
                nonisolated static let __assayRules_\(i)_\(j): [Assay.Rule] = [\(attr.ruleExprs.joined(separator: ", "))]

                """
            }
        }
        return out
    }

    /// Everything that runs between the dispatch loop and construction, in the fixed
    /// order: preprocess → field rules (with @Fallback rollback) → fallback application.
    static func postDecodeSection(_ fields: [SchemaField], spans: Bool) -> String {
        var out = ""

        // Preprocess: normalise wire values before any rule sees them.
        for (i, f) in fields.enumerated() where !f.preprocess.isEmpty {
            out += """
                if let __pp\(i) = __f\(i) {
                    __f\(i) = Assay._assayPreprocess(__pp\(i), Self.__assayPre_\(i))
                }

            """
        }

        // Field rules. A @Fallback field's violations roll back and clear the value, so
        // the fallback applies "on absence OR invalid" and the fallback value is never
        // re-validated — exactly the §6 semantics.
        for (i, f) in fields.enumerated() where !f.validations.isEmpty {
            let base = f.decodedType
            var calls = ""
            for (j, attr) in f.validations.enumerated() where !attr.ruleExprs.isEmpty {
                let override = attr.override.map { "\"\($0)\"" } ?? "nil"
                let span = spans ? "__sp\(i)" : "nil"
                calls += """
                        Assay._assayValidate(\(validationArgument(base, "__vv\(i)")), Self.__assayRules_\(i)_\(j), override: \(override), field: "\(f.wireKey)", at: \(span), path: path, &sink)

                """
            }
            guard !calls.isEmpty else { continue }
            if f.fallback != nil {
                out += """
                    if let __vv\(i) = __f\(i) {
                        let __vck\(i) = sink.checkpoint()
                \(calls)        if sink.checkpoint() > __vck\(i) {
                            sink.rollback(to: __vck\(i))
                            __f\(i) = nil
                        }
                    }

                """
            } else {
                out += """
                    if let __vv\(i) = __f\(i) {
                \(calls)    }

                """
            }
        }

        // Fallback application, with the warning that is how you find out it happened.
        for (i, f) in fields.enumerated() where f.fallback != nil {
            out += """
                if __f\(i) == nil {
                    __f\(i) = \(f.fallback!)
                    sink.add(warning: Assay.Warning(
                        code: .fallbackApplied,
                        path: path + [.key("\(f.wireKey)")]))
                }

            """
        }
        return out
    }

    /// The static preprocess-op and transform-closure declarations, emitted once.
    static func preprocessArrays(_ fields: [SchemaField]) -> String {
        var out = ""
        for (i, f) in fields.enumerated() where !f.preprocess.isEmpty {
            out += """
            nonisolated static let __assayPre_\(i): [Assay.PreprocessOp] = [\(f.preprocess.joined(separator: ", "))]

            """
        }
        return out
    }

    static func transformClosures(_ fields: [SchemaField]) -> String {
        var out = ""
        for (i, f) in fields.enumerated() {
            guard let t = f.transform else { continue }
            let output = stripOptional(f.typeName)
            // @Sendable so the static let is concurrency-safe; transform closures must be
            // capture-free, which a pure value transformation is by nature.
            out += """
            nonisolated static let __assayTransform_\(i): @Sendable (\(t.wireType)) -> \(output) = \(t.closure)

            """
        }
        return out
    }

    /// How a decoded local reaches the typed `_assayValidate` overloads.
    static func validationArgument(_ base: String, _ v: String) -> String {
        switch base {
        case "String", "Double", "[String]", "[Int]", "[Double]": return v
        case "Int", "Int32", "Int64": return base == "Int64" ? v : "Int64(\(v))"
        case "UInt": return "UInt64(\(v))"
        case "Float": return "Double(\(v))"
        default:
            // Any other array: the count-only generic overload. Non-collection custom
            // types with known rules were already diagnosed away.
            return "countOf: \(v)"
        }
    }
}
