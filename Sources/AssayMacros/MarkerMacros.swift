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
