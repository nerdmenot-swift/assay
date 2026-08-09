// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// @Key and @Ignore are *marker* macros: they expand to nothing.
//
// They exist as declared macros so that the compiler validates their argument types and
// placement, while @Schema reads them off the syntax tree of the members it was attached
// to. A plain custom attribute would not type-check its arguments.
//
// This is also the mechanism that will make `@Check` in an extension a hard error rather
// than a silent no-op: an attached macro can see where it was written and diagnose. That
// trap is real — a @Check in an extension is permanently invisible to @Schema, because
// attached macros only receive the members declared in the type's own body.
//===----------------------------------------------------------------------===//

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

public struct KeyMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

public struct ExtrasMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

public struct ValidateMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

public struct CoerceMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

public struct IgnoreMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

/// @Check / @AsyncCheck. Expands to nothing on a valid placement; the one thing it DOES
/// do is turn the in-an-extension case into a compile error, because there the check
/// would be permanently invisible to @Schema — a silent, maddening bug otherwise.
public struct CheckMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        for enclosing in context.lexicalContext {
            if enclosing.is(ExtensionDeclSyntax.self) {
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: SimpleDiagnostic(
                        "@Check must be declared in the body of the @Schema type, not in an extension — attached macros cannot see extension members, so this check would never run")))
                return []
            }
        }
        return []
    }
}

public struct PreprocessMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

public struct TransformMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

public struct FallbackMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

/// `@Inverse` — the encode direction of a `@Transform`. docs/ENCODING.md question 3.
public struct InverseMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

/// `@XML` — element/attribute/text placement, and array wrapping. docs/ENCODING.md.
public struct XMLMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

/// `@Unknown` — the forward-compatibility catch-all case. docs/ENCODING.md question 2.
public struct UnknownMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}
