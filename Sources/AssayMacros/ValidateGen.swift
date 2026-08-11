// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Emitting `_assayCheck` — the schema's rules, run against a constructed value.
// docs/VALIDATE.md, and the header of Sources/Assay/Validate.swift for the semantics.
//
// NOT OPT-IN, unlike `encodes:` and `sources:`, and that is a cost argument rather than an
// exception. Those flags exist because an encoder or a column binder is a whole extra body
// that a type which never encodes would still pay for at compile time. This body is
// generated only when the type declares a `@Validate` or a `@Check`, and then it is
// proportional to the rules already declared — one line per rule attribute, reusing the
// same `__assayRules_i_j` arrays the decode bodies share. A type with no rules gets
// nothing, so there is no cost to opt out of.
//
// It reuses `checkCalls` verbatim, which is why the value parameter is named `__result`:
// the cross-field and field-check forms are identical between decoding and validating, and
// generating a second nearly-identical version of them is how the two drift apart.
//===----------------------------------------------------------------------===//

extension SchemaMacro {

    /// Whether this type has anything to validate. Decides both the body and the
    /// conformance — emitting `Validatable` with an empty body would be a promise that
    /// `T.validate` means something for a type where it cannot.
    static func hasValidation(_ fields: [SchemaField], _ checks: [CheckDecl]) -> Bool {
        fields.contains { !$0.validations.isEmpty } || checks.contains { !$0.isAsync }
    }

    static func validateBody(
        typeName: String, fields: [SchemaField], checks: [CheckDecl]
    ) -> String {
        var out = ""

        for (i, f) in fields.enumerated() where !f.validations.isEmpty {
            // The two exclusions the round-trip law forces. See Validate.swift's header:
            // a @Fallback field's violation is SWALLOWED at decode time, and a @Transform
            // field's rules were type-checked against the wire type, not the property's.
            guard f.fallback == nil, f.transform == nil else { continue }

            // One line per rule attribute, reading the property directly. Introducing a
            // `let` first would be more readable and would cost a line of generated code
            // per field, which is the axis docs/COMPILE-TIME.md §3 says dominates.
            let value = f.isOptional ? "__vv\(i)" : "__result.\(f.identifier)"
            var calls = ""
            for (j, attr) in f.validations.enumerated() where !attr.ruleExprs.isEmpty {
                let override = attr.override.map { "\"\($0)\"" } ?? "nil"
                calls += """
                        Assay._assayValidate(\(validationArgument(f.decodedType, value)), Self.__assayRules_\(i)_\(j), override: \(override), field: "\(f.wireKey)", at: nil, path: path, &sink)

                """
            }
            guard !calls.isEmpty else { continue }

            // A nil optional is absent, not invalid — the same answer decoding gives.
            if f.isOptional {
                out += """
                    if let __vv\(i) = __result.\(f.identifier) {
                \(calls)    }

                """
            } else {
                out += calls
            }
        }

        out += Self.checkCalls(typeName, checks, fields, spans: false)

        return """
        /// Run this schema's rules against an already-constructed value. docs/VALIDATE.md.
        ///
        /// Issues carry a path and no location: there is no source document to point at.
        \(skipNote(fields))nonisolated public static func _assayCheck(
            _ __result: \(typeName),
            into sink: inout Assay.IssueSink,
            at path: [Assay.PathComponent]
        ) {
        \(out)}
        """
    }

    /// A field whose rules this body cannot re-check, NAMED — in the generated doc comment,
    /// which is where quick-help and autocomplete will show it.
    ///
    /// Deliberately not an expansion-time warning. `@Validate` beside `@Fallback` is a
    /// perfectly good decode-time combination, and warning about it because a *different*
    /// entry point cannot re-check it would put a diagnostic on correct code — which is how
    /// projects end up with a warning everyone has learned to scroll past. The fact belongs
    /// where someone reaching for `validate` will read it.
    static func skipNote(_ fields: [SchemaField]) -> String {
        var reasons: [String] = []
        for f in fields where !f.validations.isEmpty {
            if f.transform != nil {
                reasons.append("`\(f.identifier)` (@Transform: its rules are type-checked "
                    + "against the wire type, and the property holds the output)")
            } else if f.fallback != nil {
                reasons.append("`\(f.identifier)` (@Fallback: decoding swallows a violation "
                    + "here, so reporting it would reject a value decoding accepted)")
            }
        }
        guard !reasons.isEmpty else { return "" }
        return """
        ///
        /// Rules NOT re-checked here, and why — decoding still applies all of them:
        /// \(reasons.joined(separator: ",\n/// "))

        """
    }
}
