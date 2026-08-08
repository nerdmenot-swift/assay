// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

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
        ValidateMacro.self,
        CheckMacro.self,
        PreprocessMacro.self,
        TransformMacro.self,
        FallbackMacro.self,
        DateFormatMacro.self,
        InverseMacro.self,
    ]
}
