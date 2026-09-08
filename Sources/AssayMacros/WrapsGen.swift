// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `@Wraps` — sugar for the validated-scalar wrapper. EXPERIENCE §8, ROADMAP §6.
//
// ```swift
// @Wraps(String.self, .email)
// struct EmailAddress {}
// ```
//
// WHY THIS WAITED FOR `Assayer<T>`, and why it is small now that it exists. Before
// `AssayerBacked`, a wrapper type had to hand-write `_assay(from: inout AssayReader, ...)`
// twice — once for bytes and once for `RawValue` — threading a path array and reporting into
// a sink. This macro would have had to emit both, which is two decode bodies per wrapper and
// a real compile-time cost on a type whose whole job is to hold one scalar.
//
// It now emits a `static let assaySchema` and nothing else. The bodies come from
// `AssayerBacked`'s `@inlinable` default implementations, which exist once in `Assay` rather
// than once per wrapper. That is the layering the rest of the library uses — a closed enum
// needs no macro, `@Schema enum` exists only for `@Unknown` — and it is why this is sugar
// over a hand-writable spelling rather than a parallel mechanism.
//
// ONE RULE ARRAY SERVES BOTH DIRECTIONS. `init?(_:)` and the decode path run the same
// `__assayWrapRules`, which is what makes "the type cannot hold an invalid value" true
// rather than approximately true.
//
// THE WRAPPED TYPE IS RESTRICTED to the scalars `Assayer` has leaves for. A macro is
// syntactic: it sees the token `Foo` and cannot know whether `Foo` is a scalar, a struct or
// a typealias. Restricting to a known token set is the only way it can emit a correct leaf
// AND type-check the rules against it; anything else gets a purpose-written diagnostic
// naming the alternative, which is to write the `AssayerBacked` conformance by hand.
//===----------------------------------------------------------------------===//

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

public struct WrapsMacro {

    /// Wrapped type token -> the `Assayer` leaf that reads it.
    static let leaves: [String: String] = [
        "String": "string",
        "Int64": "int",
        "Double": "double",
        "Bool": "bool",
    ]

    /// What `RuleTypeCheck` should type-check the rules against.
    static func category(_ type: String) -> RuleTypeCheck.FieldCategory {
        switch type {
        case "String": return .string
        case "Int64": return .integer
        case "Double": return .floating
        default: return .bool
        }
    }

    struct Parsed {
        let wrapped: String
        let rules: [String]
    }

    static func parse(
        _ node: AttributeSyntax, _ decl: some DeclGroupSyntax,
        _ context: some MacroExpansionContext
    ) -> Parsed? {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self),
              let first = args.first else {
            context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                "@Wraps needs the wrapped type: @Wraps(String.self, .email)")))
            return nil
        }
        var wrapped = first.expression.trimmedDescription
        if wrapped.hasSuffix(".self") { wrapped.removeLast(5) }

        guard leaves[wrapped] != nil else {
            context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                "@Wraps can wrap \(leaves.keys.sorted().joined(separator: ", ")), not "
                + "'\(wrapped)'. A macro sees the type's NAME and nothing else, so it cannot "
                + "know how to read one it does not recognise. For any other type, write the "
                + "`AssayerBacked` conformance by hand — it is three lines and `@Wraps` is "
                + "only sugar over it.")))
            return nil
        }

        // A body with stored properties would collide with the generated storage.
        for m in decl.memberBlock.members {
            if let v = m.decl.as(VariableDeclSyntax.self),
               v.bindings.contains(where: { $0.accessorBlock == nil }) {
                context.diagnose(Diagnostic(node: Syntax(v), message: SimpleDiagnostic(
                    "@Wraps generates the storage, so the type's body must not declare a "
                    + "stored property. Computed properties and methods are fine.")))
                return nil
            }
        }

        let rules = args.dropFirst().map { $0.expression.trimmedDescription }
        // The same expansion-time check `@Validate` gets, so `.email` on an Int64 wrapper is
        // a compile error here exactly as it is on a field.
        let cat = category(wrapped)
        for r in rules {
            var name = r
            while name.hasPrefix(".") { name.removeFirst() }
            if let paren = name.firstIndex(of: "(") { name = String(name[name.startIndex..<paren]) }
            if let wanted = RuleTypeCheck.expectedCategory(rule: name, on: cat) {
                context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                    "'.\(name)' applies to \(wanted), and @Wraps(\(wrapped).self) wraps a "
                    + "\(wrapped).")))
                return nil
            }
        }
        return Parsed(wrapped: wrapped, rules: rules)
    }
}

extension WrapsMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let p = parse(node, declaration, context) else { return [] }
        let rules = p.rules.joined(separator: ", ")

        return [
            """
            /// The wrapped value. Immutable: a wrapper that can be mutated into an invalid
            /// state is not a wrapper.
            public let raw: \(raw: p.wrapped)
            """,
            """
            nonisolated static let __assayWrapRules: [Assay.Rule] = [\(raw: rules)]
            """,
            """
            /// Trusted construction, used by the decode path after the rules have already
            /// run. Not public: the whole point is that a public initialiser validates.
            @usableFromInline
            init(__assayUnchecked raw: \(raw: p.wrapped)) { self.raw = raw }
            """,
            """
            /// Fails when the value does not satisfy the same rules the decoder applies.
            /// One rule array, two callers — which is what makes "this type cannot hold an
            /// invalid value" true rather than nearly true.
            public init?(_ raw: \(raw: p.wrapped)) {
                var __sink = Assay.IssueSink(limits: .default)
                Assay._assayValidate(raw, Self.__assayWrapRules, override: nil,
                                     field: "", at: nil, path: [], &__sink)
                guard __sink.isValid else { return nil }
                self.raw = raw
            }
            """,
        ]
    }
}

extension WrapsMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let p = parse(node, declaration, context) else { return [] }
        let leaf = Self.leaves[p.wrapped]!
        let validate = p.rules.isEmpty
            ? ""
            : ".validate(\(p.rules.joined(separator: ", ")))"

        // `Equatable`/`Hashable`/`CustomStringConvertible` are DECLARED here and synthesised
        // by the compiler. The macro cannot check that `String` is `Equatable` — it sees a
        // token — so declaring the conformance and letting the type checker do the work is
        // the only sound route.
        let ext: DeclSyntax = """
        extension \(type): Assay.AssayerBacked, Swift.Equatable, Swift.Hashable,
                           Swift.CustomStringConvertible {
            nonisolated public static var assaySchema: Assay.Assayer<\(type)> {
                Assay.Assayer.\(raw: leaf)\(raw: validate)
                    .map { \(type)(__assayUnchecked: $0) }
            }
            public var description: String { String(describing: raw) }
        }
        """
        return [ext.as(ExtensionDeclSyntax.self)!]
    }
}
