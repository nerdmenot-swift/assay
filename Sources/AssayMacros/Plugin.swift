import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct AssayPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        SchemaMacro.self,
        KeyMacro.self,
        IgnoreMacro.self,
        ExtrasMacro.self,
        CoerceMacro.self,
    ]
}
