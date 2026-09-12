import SwiftSyntax
import SwiftSyntaxMacros
import SwiftCompilerPlugin

public struct NoOp: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

@main struct Plugin: CompilerPlugin { let providingMacros: [any Macro.Type] = [NoOp.self] }
