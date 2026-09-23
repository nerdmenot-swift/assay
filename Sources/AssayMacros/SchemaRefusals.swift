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

        // THE TYPES THE MACRO CAN SEE ARE WRONG. A newcomer's most common error, found by a
        // 54-declaration probe battery on 2026-09-10: each of these compiled to
        // "type 'X' has no member '_assay'" inside the expansion, naming an underscored
        // internal at a line the user never wrote. The macro sees the type's SPELLING,
        // which is enough to refuse every one of these with the alternative in the message.
        // `@Ignore` fields are exempt (checked first, below): the type is never decoded.
        // With a `@Transform`, the DECLARED type is the closure's output and can be
        // anything — a `Set`, a `URL`, a `Decimal` is precisely what the attribute is for;
        // the shape that has to be decodable is the closure's parameter, the wire type.
        let wireTypeName =
            SchemaMacro.transform(from: attrs, context: context)?.wireType ?? typeName
        if !set.contains("Ignore"), !set.contains("Extras"),
            let why = SchemaRefusals.undecodableShape(wireTypeName)
        {
            return refuse(why)
        }

        // `@Ignore` beside anything else the macro would have acted on. The field is
        // excluded, so the other attribute would never run — and a rule that never runs
        // is the exact shape of bug this table exists to refuse.
        if set.contains("Ignore") {
            let acted: Set<String> = [
                "Validate", "Preprocess", "Transform", "Inverse",
                "Fallback", "DateFormat", "Coerce", "OneOrMany",
                "Key", "XML", "Extras", "Inline"
            ]
            if let other = names.first(where: { acted.contains($0) }) {
                return refuse(
                    "@Ignore excludes this property from decoding, so @\(other) "
                        + "would never run. Remove one of them.")
            }
            return true
        }

        // An empty wire key. `@Key("")` decoded `{"": 1}` and its missing-key message was
        // `" is required"`; nobody meant that.
        for a in attrs where a.attributeName.trimmedDescription == "Key" {
            guard let args = a.arguments?.as(LabeledExprListSyntax.self) else { continue }
            for arg in args {
                if let lit = arg.expression.as(StringLiteralExprSyntax.self),
                    lit.segments.description.isEmpty
                {
                    return refuse(
                        "@Key names an empty wire key. A key has at least one "
                            + "character; remove the attribute to use the property's own name.")
                }
            }
        }

        // `@Key("x")` and `@Key(path:)` together. One field has one wire location; until
        // 2026-09-10 whichever attribute came last won, silently.
        var positionalKey = false, pathKey = false
        for a in attrs where a.attributeName.trimmedDescription == "Key" {
            if let args = a.arguments?.as(LabeledExprListSyntax.self),
                args.first?.label?.text == "path"
            {
                pathKey = true
            } else {
                positionalKey = true
            }
        }
        if positionalKey && pathKey {
            return refuse(
                "@Key(\"…\") and @Key(path:) on the same property — a field has one "
                    + "wire location. Keep the path (its last segment is the key) or the key.")
        }

        // `@OneOrMany` accepts a single value where an ARRAY is declared.
        if set.contains("OneOrMany"), SchemaMacro.arrayElement(base) == nil {
            return refuse(
                "@OneOrMany accepts one value where an array is declared, and "
                    + "'\(typeName)' is not an array. Remove it, or declare `[\(base)]`.")
        }

        // `@Key` beside `@Extras`. `@Extras` is the bag for keys the schema does NOT name,
        // so naming a wire key for it is a contradiction: there is no single key to read.
        // It compiled and the `@Key` was dropped on the floor.
        if set.contains("Extras"), set.contains("Key") {
            return refuse(
                "@Extras collects the keys the schema does not name, so it has no "
                    + "wire key of its own and @Key cannot apply to it. Remove the @Key.")
        }

        // `@Key(path:)` beside `@Inline`. `@Inline` splices the nested type's fields into
        // THIS type's dispatch table — the inlined fields sit where this type's own fields
        // sit — and a path moves the whole field somewhere else. One of them has to be
        // wrong, and until now the answer was silently "the path".
        if set.contains("Inline"), pathKey {
            return refuse(
                "@Inline splices the nested type's fields into this type's own "
                    + "keys, so there is no single location for @Key(path:) to name. Use one: "
                    + "@Inline for a flattened type, or @Key(path:) for a nested one.")
        }

        // `@Coerce` on something that is not a coercible scalar. Coercion is the "\"8080\" is
        // an Int" policy and it is implemented by the `…Coercing` reader primitives, which
        // exist for exactly the fifteen scalar spellings below. On anything else — a nested
        // @Schema type, an array, a dictionary, a Date — the attribute parsed, type-checked
        // and did nothing at all.
        let coercible: Set<String> = [
            "String", "Int", "Int64", "Int32", "Int16", "Int8",
            "UInt", "UInt64", "UInt32", "UInt16", "UInt8",
            "Double", "Float", "Bool"
        ]
        if set.contains("Coerce") {
            let wire = SchemaMacro.stripOptional(wireTypeName.trimmingWhitespace())
            if !coercible.contains(wire) {
                return refuse(
                    "@Coerce accepts a scalar written as the wrong JSON type — "
                        + "\"8080\" for an Int, \"true\" for a Bool — and '\(typeName)' is not one "
                        + "of the scalars it applies to. Remove it; a nested type coerces its "
                        + "own fields, and an array coerces through its element's declaration.")
            }
        }

        // `@Preprocess` ops are string operations on the WIRE value — which is the
        // `@Transform` closure's parameter type when there is one, and the declared type
        // otherwise. The first version of this check read the declared type and refused
        // `@Preprocess(.trim) @Transform({ (s: String) in s.count }) var n: Int`, which is
        // exactly the pairing the two attributes exist for. Without the check at all, the
        // failure was a type error INSIDE the expansion at a line the author never wrote.
        if set.contains("Preprocess"), SchemaMacro.stripOptional(wireTypeName) != "String" {
            return refuse(
                "@Preprocess(.trim, .lowercase, …) normalises a String before its "
                    + "rules run; '\(typeName)' is not one. Use @Transform for a non-string "
                    + "conversion.")
        }

        return true
    }

    /// Why a spelled type cannot be a field, or nil when the spelling is not one of the
    /// shapes the macro can rule out. Nominal types it has never heard of pass through:
    /// they may be `@Schema` types, `AssayerBacked` wrappers or enums with a conformance,
    /// and the emitted `_assayRequire` assertion gives THOSE a legible error instead.
    static func undecodableShape(_ typeName: String) -> String? {
        let t = typeName.trimmingWhitespace()
        let base = SchemaMacro.stripOptional(t)

        if t.hasSuffix("!") {
            return "'\(t)' is implicitly unwrapped, which a decoder cannot honour — an absent "
                + "key has to be nil or an error. Declare '\(String(t.dropLast()))?'."
        }
        if base.hasSuffix("?") || base.hasPrefix("Optional<") {
            return "'\(t)' is an optional of an optional. A document has one kind of absence; "
                + "declare '\(SchemaMacro.stripOptional(base))?'."
        }
        if base.containsSubstring("->") {
            return "'\(t)' is a function type and cannot be decoded."
        }
        if base.hasPrefix("(") {
            return "'\(t)' is a tuple, and no wire format has one. Declare a nested @Schema "
                + "struct for the fields, or an array if the parts are the same type."
        }
        if base == "Any" || base == "AnyObject" || base == "any Sendable" {
            return "'\(t)' cannot be decoded — every field has one wire shape. For a value of "
                + "unknown shape declare `RawValue` (format-neutral) or `JSON.Value`."
        }
        if base.hasPrefix("Set<") {
            let element = String(base.dropFirst(4).dropLast())
            return "'\(t)' cannot be decoded directly: a document carries an ordered array. "
                + "Declare `[\(element)]`, or keep the Set with "
                + "`@Transform({ (a: [\(element)]) in Set(a) }) var …: Set<\(element)>`."
        }
        if let element = SchemaMacro.arrayElement(base),
            element.hasSuffix("?") || element.hasPrefix("Optional<")
        {
            return "'\(t)' is an array of optionals. A JSON array holds values or nulls; "
                + "declare `[\(SchemaMacro.stripOptional(element))]` (a null element is an "
                + "error) or decode as `[RawValue]` and inspect the nulls yourself."
        }
        switch base {
        case "Character":
            return "'Character' is not a field type; declare `String` and take its first "
                + "character, or use @Transform."
        case "Data", "Foundation.Data":
            return "'Data' is not a field type: a document carries bytes as text (base64, hex). "
                + "Declare `String` and decode with @Transform, or `[UInt8]` for a byte array."
        case "URL", "Foundation.URL":
            return "'URL' is not a field type. Declare `@Validate(.url) var …: String` — the "
                + "rule is what a URL field usually wants — and construct the URL where you "
                + "use it, or write an `AssayerBacked` wrapper."
        case "Decimal", "Foundation.Decimal":
            return "'Decimal' is not a field type: JSON numbers are doubles, and a decimal "
                + "quantity should travel as a string. Declare `String` and convert with "
                + "@Transform, or write an `AssayerBacked` wrapper that parses it exactly."
        case "UUID", "Foundation.UUID":
            // Legal WITH AssayFoundation, which supplies the conformance; without it the
            // type is not in scope at all and the compiler says so first. Pass.
            return nil
        default:
            return nil
        }
    }

    /// Type-level combinations, once the fields are known.
    static func type(
        config: SchemaConfig,
        fields: [SchemaField],
        extras: SchemaField?,
        typeName: String,
        isGeneric: Bool,
        node: AttributeSyntax,
        context: some MacroExpansionContext
    ) -> Bool {
        func refuse(_ m: String) -> Bool {
            context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(m)))
            return false
        }

        // A generic struct. The generated body holds `static let` tables — the window
        // table, the rule arrays — and Swift has no static stored properties in generic
        // types, so the failure was "static stored properties not supported in generic
        // types" inside the expansion.
        if isGeneric {
            return refuse(
                "@Schema does not support generic types: the generated dispatch "
                    + "tables are static stored properties, which a generic type cannot have. "
                    + "Declare a concrete type, or decode the varying part as `RawValue` and "
                    + "convert it afterwards.")
        }

        // `@Extras` holds keys the schema did not declare, so its VALUE type has to hold
        // anything: `RawValue` (format-neutral) or `JSON.Value` (JSON-only, full fidelity).
        // Anything else was "requires that 'Int' conform to 'JSONCollectible'".
        if let e = extras, let value = SchemaMacro.dictionaryValue(e.typeName),
            !SchemaMacro.isCollectible(value)
        {
            return refuse(
                "@Extras must be `[String: RawValue]` or `[String: JSON.Value]`; "
                    + "'\(e.identifier)' is declared '\(e.typeName)'. The sink holds keys the "
                    + "schema did not declare, so its values can be any shape.")
        }

        // A type that declares nothing to decode. `S.parse` would not exist and the reason
        // would be "no member", three files away from the empty braces.
        let active = fields.filter { !$0.isIgnored && !$0.isExtras }
        if active.isEmpty, extras == nil {
            return refuse(
                "@Schema on '\(typeName)' found no stored properties to decode. "
                    + "Declare at least one `var name: Type`, or remove the attribute.")
        }

        // `@XML(...)` in either form on a type that will never see an XML document.
        if !config.formats.xml {
            if config.xmlRoot != nil {
                return refuse(
                    "@XML(root:) names the root element of an XML document, and "
                        + "'\(typeName)' does not decode XML. Add `formats: .xml` (or `.all`) "
                        + "to @Schema, or remove the attribute.")
            }
            if let f = fields.first(where: { $0.xmlPlacement != nil }) {
                return refuse(
                    "@XML(.\(f.xmlPlacement!)) on '\(f.identifier)' places it in an "
                        + "XML document, and '\(typeName)' does not decode XML. Add "
                        + "`formats: .xml` (or `.all`) to @Schema, or remove the attribute.")
            }
        }

        // `@Extras` with `.reject`: every unknown key is an issue AND goes to the sink? The
        // two answers contradict; `.ignore`/`.warn` + `@Extras` are rewritten to `.collect`
        // in `SchemaConfig.effectiveUnknownKeys` instead, because there the sink is the
        // clearer statement of intent.
        if extras != nil, config.unknownKeys == "reject" {
            return refuse(
                "@Schema(unknownKeys: .reject) refuses unknown keys, and @Extras "
                    + "collects them — both cannot hold. Use `.collect` (or drop the option: "
                    + "@Extras implies it), or remove the @Extras property.")
        }

        return true
    }
}
