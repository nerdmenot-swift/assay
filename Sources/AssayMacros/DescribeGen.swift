// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// `@Schema(describes: true)` — the descriptor body. EXPERIENCE.md §14, ROADMAP.md §11.
//
// This file is deliberately SMALL, and that is the whole design decision. The obvious
// implementation emits the JSON Schema text from the macro; this one emits a value naming what
// the macro already knows, and `AssayCore/JSONSchemaRender.swift` turns it into a document
// once, at runtime, in one copy.
//
// The reason is measured rather than aesthetic. `docs/COMPILE-TIME.md`'s cost model is
// `9 ms fixed + 7.3 ms per field` and it tracks **generated body size**; rule 1 of
// `CLAUDE.md`'s hard constraints exists because a 256-element array literal cost 16% of
// expansion time. The rule-to-keyword mapping is ~120 lines of branching — `.min` becomes
// `minLength` on a String, `minimum` on a number, `minItems` on an array — and putting it in
// every user's expansion, once per type, is precisely the thing that budget forbids.
//
// AND THE RULES COST NOTHING EXTRA. The descriptor references `Self.__assayRules_i_j`, the
// same `static let` the validator body already needs. A field with three rules contributes one
// identifier to this body, not three rule literals.
//
// NESTED TYPES: `Author.self` as an `any Assay.SchemaDescribing.Type`. A macro reads the token
// `Author` and cannot know what it is — so the metatype makes the TYPE CHECKER verify the
// conformance, and a nested type that forgot `describes: true` is a compile error naming the
// real problem instead of a schema that silently describes it as `{}`. Same device
// `ColumnDecodable` already uses.
//===----------------------------------------------------------------------===//

import SwiftSyntax

extension SchemaMacro {

    /// `@Schema(describes: true)`. Opt-in, like `encodes:` and `sources:`, for the reason in
    /// the file header: a type that never emits a schema document must not carry one.
    static func describes(from node: AttributeSyntax) -> Bool {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self) else { return false }
        for arg in args where arg.label?.text == "describes" {
            return arg.expression.trimmedDescription == "true"
        }
        return false
    }

    static func describeBody(
        typeName: String, fields: [SchemaField], policy: String, groups: [PathGroup]
    ) -> String {
        var entries: [String] = []
        for (i, f) in fields.enumerated() {
            // A path field's wire key is nested, and a flat `properties` map cannot express
            // that. Described as the FULL dotted path in the key, which is honest about where
            // the value lives without pretending the shape is flat — see `describeDiagnostics`,
            // which refuses the combination rather than emitting a wrong document.
            let aliases = f.aliases.map { "\"\($0)\"" }.joined(separator: ", ")
            let rulesExpr = ruleArrayReference(f, i)
            let required = !f.isOptional && f.defaultExpr == nil && f.fallback == nil
            var entry = """
                    Assay.FieldDescriptor(
                        wireKey: "\(f.wireKey)",
                        aliases: [\(aliases)],
                        propertyName: "\(f.identifier)",
                        type: \(typeDescriptor(f.typeName, f)),
                        isRequired: \(required),
                        rules: \(rulesExpr))
            """
            if let t = f.transform {
                // `.input` and `.output` differ exactly here. Zod shipped one document first
                // and added the distinction in v4 after finding it wrong.
                entry = """
                        Assay.FieldDescriptor(
                            wireKey: "\(f.wireKey)",
                            aliases: [\(aliases)],
                            propertyName: "\(f.identifier)",
                            type: \(typeDescriptor(f.typeName, f)),
                            wireType: \(typeDescriptor(t.wireType, f)),
                            isRequired: \(required),
                            rules: \(rulesExpr))
                """
            }
            entries.append(entry)
        }
        _ = groups

        return """
        /// This type's shape, for `jsonSchema(for:)`. `docs/EXPERIENCE.md` §14.
        ///
        /// A descriptor rather than document text: the rule-to-keyword mapping lives once in
        /// `AssayCore`, not once per type in every user's expansion.
        nonisolated public static var _assaySchemaDescriptor: Assay.SchemaDescriptor {
            Assay.SchemaDescriptor(
                typeName: "\(typeName)",
                fields: [
        \(entries.joined(separator: ",\n"))
                ],
                rejectsUnknownKeys: \(policy == "reject"))
        }
        """
    }

    /// The `static let` the validator already holds, or `[]`. Never a fresh rule literal —
    /// that would double every rule array in the expansion for no benefit.
    static func ruleArrayReference(_ f: SchemaField, _ i: Int) -> String {
        let arrays = f.validations.enumerated()
            .filter { !$0.element.ruleExprs.isEmpty }
            .map { "Self.__assayRules_\(i)_\($0.offset)" }
        if arrays.isEmpty { return "[]" }
        if arrays.count == 1 { return arrays[0] }
        return "(" + arrays.joined(separator: " + ") + ")"
    }

    /// A declared type token to a `TypeDescriptor` expression.
    ///
    /// Unrecognised tokens become `.nested(X.self)` when they could be a schema type, which is
    /// what puts the conformance check on the type checker. There is no way for a macro to
    /// tell `Author` (a nested schema) from `URL` (not one) — so it emits the metatype and
    /// lets the compiler answer, which produces a real diagnostic instead of a wrong document.
    static func typeDescriptor(_ type: String, _ f: SchemaField) -> String {
        var t = type
        if t.hasSuffix("?") {
            t.removeLast()
            return ".optional(\(typeDescriptor(t, f)))"
        }
        if let element = arrayElement(t) { return ".array(\(typeDescriptor(element, f)))" }
        if let value = dictionaryValue(t) { return ".dictionary(\(typeDescriptor(value, f)))" }
        if isDateType(t) {
            // Whether a date is a string or a number on the wire depends on its FORMAT, which
            // is why this is not a constant. `.unixSeconds` is a number; describing it as
            // `date-time` would make a correct client emit a document this type rejects.
            // `String.contains(_: String)` is macOS 13; the macro target's floor is lower.
            // `range(of:)` needs Foundation, which the macro target does not import either,
            // so this is spelled with what is available everywhere.
            let numeric = (f.dateFormats ?? []).contains {
                hasSubstring($0.lowercased(), "unix")
            }
            return ".date(numeric: \(numeric))"
        }
        switch t {
        case "String": return ".string"
        case "Bool": return ".boolean"
        case "Int", "Int8", "Int16", "Int32", "Int64",
             "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            return ".integer"
        case "Double", "Float": return ".number"
        case "RawValue", "Assay.RawValue", "JSON.Value", "Assay.JSON.Value":
            // Any value, deliberately. These fields exist to hold whatever arrived.
            return ".opaque(\"\(t)\")"
        default:
            return ".nested(\(t).self)"
        }
    }

    /// Substring search without Foundation and without the macOS 13 `contains(_: String)`.
    /// Only ever runs over a handful of short format spellings at expansion time.
    static func hasSubstring(_ haystack: String, _ needle: String) -> Bool {
        let h = Array(haystack.utf8), n = Array(needle.utf8)
        guard !n.isEmpty, h.count >= n.count else { return false }
        for start in 0...(h.count - n.count) {
            var match = true
            for j in 0..<n.count where h[start + j] != n[j] { match = false; break }
            if match { return true }
        }
        return false
    }

    /// Combinations the descriptor cannot describe faithfully. Refused at expansion with a
    /// reason, rather than emitting a document that is quietly wrong — a generated schema
    /// nobody can check is worse than no generated schema.
    static func describeDiagnostics(_ fields: [SchemaField]) -> [String] {
        var out: [String] = []
        if fields.contains(where: { $0.pathSegments != nil }) {
            out.append("@Schema(describes: true) cannot describe a @Key(path:) field. JSON "
                + "Schema's `properties` map is flat, so a field living at `profile.name` "
                + "would have to be described either as a top-level `profile.name` key (which "
                + "no document has) or as a nested object (which would claim this type reads "
                + "keys it does not). Use a nested @Schema type for the shape you want to "
                + "publish, or drop `describes: true`.")
        }
        if fields.contains(where: { $0.xmlPlacement != nil }) {
            out.append("@Schema(describes: true) describes a JSON document, and @XML placement "
                + "(.attribute/.text/.wrapped) has no JSON equivalent — an attribute is not a "
                + "property. Emitting a JSON Schema for this type would describe a document "
                + "shape that only exists in XML.")
        }
        return out
    }
}
