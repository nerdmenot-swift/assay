// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Every expansion-time refusal, in one place.
//
// THE PRINCIPLE: an option or attribute that is accepted and then does nothing is worse
// than one that is refused. `CLAUDE.md` says it, `docs/UNIONS.md` says it, and on
// 2026-09-10 an audit found eleven declarations that violated it anyway — `@XML(root:)` on a
// type with no XML format, `@Extras` on a type that never collects, `@Key("x")` beside
// `@Key(path:)`, `@Ignore` beside `@Validate`, an empty `@Schema struct {}` — each expanding
// without a word and then doing less than it said. The checks existed for other cases; they
// were scattered across `expansion`, `field(from:)` and the union path, so each new option
// had to remember to add its own and several did not.
//
// Two entry points, because the information arrives at two moments: `property` runs inside
// `field(from:)` with the raw attribute list in hand, before `@Ignore` discards the rest;
// `type` runs once the fields are known. Both return `false` having diagnosed, and every
// diagnostic names what to write instead — a macro that says only "invalid" leaves the
// author to guess at the model.
//===----------------------------------------------------------------------===//

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

enum SchemaRefusals {

    /// Attribute combinations on one property that cannot mean what they say.
    static func property(
        attrs: [AttributeSyntax],
        typeName: String,
        varDecl: VariableDeclSyntax,
        context: some MacroExpansionContext
    ) -> Bool {
        let names = attrs.map { $0.attributeName.trimmedDescription }
        let set = Set(names)
        func refuse(_ m: String) -> Bool {
            context.diagnose(Diagnostic(node: Syntax(varDecl), message: SimpleDiagnostic(m)))
            return false
        }
        let base = SchemaMacro.stripOptional(typeName)

        // `@Ignore` beside anything else the macro would have acted on. The field is
        // excluded, so the other attribute would never run — and a rule that never runs
        // is the exact shape of bug this table exists to refuse.
        if set.contains("Ignore") {
            let acted: Set<String> = ["Validate", "Preprocess", "Transform", "Inverse",
                                      "Fallback", "DateFormat", "Coerce", "OneOrMany",
                                      "Key", "XML", "Extras", "Inline"]
            if let other = names.first(where: { acted.contains($0) }) {
                return refuse("@Ignore excludes this property from decoding, so @\(other) "
                    + "would never run. Remove one of them.")
            }
            return true
        }

        // `@Key("x")` and `@Key(path:)` together. One field has one wire location; until
        // 2026-09-10 whichever attribute came last won, silently.
        var positionalKey = false, pathKey = false
        for a in attrs where a.attributeName.trimmedDescription == "Key" {
            if let args = a.arguments?.as(LabeledExprListSyntax.self),
               args.first?.label?.text == "path" { pathKey = true } else { positionalKey = true }
        }
        if positionalKey && pathKey {
            return refuse("@Key(\"…\") and @Key(path:) on the same property — a field has one "
                + "wire location. Keep the path (its last segment is the key) or the key.")
        }

        // `@OneOrMany` accepts a single value where an ARRAY is declared.
        if set.contains("OneOrMany"), SchemaMacro.arrayElement(base) == nil {
            return refuse("@OneOrMany accepts one value where an array is declared, and "
                + "'\(typeName)' is not an array. Remove it, or declare `[\(base)]`.")
        }

        // `@Preprocess` ops are string operations. Without this the failure was a type
        // error INSIDE the expansion — "cannot convert value of type 'Int' to expected
        // argument type 'String'" at a line the author never wrote.
        if set.contains("Preprocess"), base != "String" {
            return refuse("@Preprocess(.trim, .lowercase, …) normalises a String before its "
                + "rules run; '\(typeName)' is not one. Use @Transform for a non-string "
                + "conversion.")
        }

        return true
    }

    /// Type-level combinations, once the fields are known.
    static func type(
        config: SchemaConfig,
        fields: [SchemaField],
        extras: SchemaField?,
        typeName: String,
        node: AttributeSyntax,
        context: some MacroExpansionContext
    ) -> Bool {
        func refuse(_ m: String) -> Bool {
            context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(m)))
            return false
        }

        // A type that declares nothing to decode. `S.parse` would not exist and the reason
        // would be "no member", three files away from the empty braces.
        let active = fields.filter { !$0.isIgnored && !$0.isExtras }
        if active.isEmpty, extras == nil {
            return refuse("@Schema on '\(typeName)' found no stored properties to decode. "
                + "Declare at least one `var name: Type`, or remove the attribute.")
        }

        // `@XML(...)` in either form on a type that will never see an XML document.
        if !config.formats.xml {
            if config.xmlRoot != nil {
                return refuse("@XML(root:) names the root element of an XML document, and "
                    + "'\(typeName)' does not decode XML. Add `formats: .xml` (or `.all`) "
                    + "to @Schema, or remove the attribute.")
            }
            if let f = fields.first(where: { $0.xmlPlacement != nil }) {
                return refuse("@XML(.\(f.xmlPlacement!)) on '\(f.identifier)' places it in an "
                    + "XML document, and '\(typeName)' does not decode XML. Add "
                    + "`formats: .xml` (or `.all`) to @Schema, or remove the attribute.")
            }
        }

        // `@Extras` with `.reject`: every unknown key is an issue AND goes to the sink? The
        // two answers contradict; `.ignore`/`.warn` + `@Extras` are rewritten to `.collect`
        // in `SchemaConfig.effectiveUnknownKeys` instead, because there the sink is the
        // clearer statement of intent.
        if extras != nil, config.unknownKeys == "reject" {
            return refuse("@Schema(unknownKeys: .reject) refuses unknown keys, and @Extras "
                + "collects them — both cannot hold. Use `.collect` (or drop the option: "
                + "@Extras implies it), or remove the @Extras property.")
        }

        return true
    }
}
