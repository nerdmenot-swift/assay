// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Descriptor -> JSON Schema 2020-12. `EXPERIENCE.md` §14.
//
// This file is the reason `SchemaDescriptor.swift` exists: the rule-to-keyword mapping is
// substantial, it lives here exactly once, and it never enters a user's expansion.
//
// WHERE A RULE'S KEYWORD DEPENDS ON THE FIELD'S TYPE. `.min(3)` is `minLength` on a `String`,
// `minimum` on a number and `minItems` on an array — one `Rule` case, three keywords. The
// validator does not need to know which, because it dispatches on the value it is handed at
// runtime; the renderer has no value, only the declared type, which is why the mapping takes
// both and why it could not have been written on `Rule` itself.
//
// THE ONE RULE THIS FILE HOLDS: **when in doubt, describe MORE than the type accepts, never
// less.** A schema that under-documents costs a reader some guessing. A schema that is too
// strict makes a correct client unusable, and the client author has no way to discover that
// the schema is wrong rather than their code. The two errors are not symmetric.
//
// So a rule with no *exact* 2020-12 equivalent is recorded in `description` prose rather than
// approximated with a keyword that might be narrower than the real check:
//
//   .trimmed, .lowercased   ASSERTIONS, not normalisations — Assay reports `not_trimmed`, it
//                           does not trim. (An earlier version of this file said the opposite
//                           and a test caught it.) A `pattern` could express them, but only
//                           approximately: `isTrimmed` treats space/tab/CR/LF as whitespace
//                           while ECMA-262's `\s` also matches Unicode separators and NBSP, and
//                           `.lowercased` compares against Swift's full Unicode case folding,
//                           which no character class reproduces. Either pattern would be
//                           NARROWER than the real check in some direction, which is the
//                           direction that must not happen.
//   .before/.after/.between the bound is epoch seconds and the wire form is a date STRING, so
//                           `minimum`/`maximum` would compare the wrong things, and there is
//                           no 2020-12 keyword for "this date string is before that one".
//
// Genuinely nothing to say, and dropped:
//   .each                   applies to elements; rendered on `items`, not dropped
//   .messageOnly            a message, not a constraint
//   .finite                 JSON has no infinities to exclude
//   .invalidRuleDate        a malformed bound; it fires at runtime, it describes nothing
//===----------------------------------------------------------------------===//

extension SchemaDescriptor {

    /// The JSON Schema 2020-12 document for this type, as a `JSON.Value` — not text, so a
    /// caller embedding it in an OpenAPI document does not have to re-parse it. `description()`
    /// renders the text.
    public func jsonSchema(for face: SchemaFace = .input) -> JSONSchemaValue {
        var root = body(for: face, includeDialect: true)
        // `title` after `$schema` and `type`, which is the order a reader expects. Inserted
        // rather than appended for that reason — member order here is the rendered order.
        let at = min(1, root.count)
        root.insert(("title", .string(typeName)), at: at)
        return .object(root)
    }

    func body(for face: SchemaFace, includeDialect: Bool) -> [(String, JSONSchemaValue)] {
        var out: [(String, JSONSchemaValue)] = []
        if includeDialect {
            out.append(("$schema", .string("https://json-schema.org/draft/2020-12/schema")))
        }
        out.append(("type", .string("object")))

        var properties: [(String, JSONSchemaValue)] = []
        var required: [JSONSchemaValue] = []
        for f in fields {
            let shape = (face == .input ? (f.wireType ?? f.type) : f.type)
            properties.append((f.wireKey, JSONSchemaRender.schema(for: shape, rules: f.rules)))
            // An alias is a second accepted spelling of the SAME field. 2020-12 has no way to
            // say "exactly one of these keys", so each alias is described as an optional
            // property of the same shape — permissive rather than wrong, per the file header.
            for alias in f.aliases {
                properties.append((alias,
                                   JSONSchemaRender.schema(for: shape, rules: f.rules)))
            }
            if f.isRequired && f.aliases.isEmpty { required.append(.string(f.wireKey)) }
        }
        out.append(("properties", .object(properties)))
        if !required.isEmpty { out.append(("required", .array(required))) }
        if rejectsUnknownKeys { out.append(("additionalProperties", .bool(false))) }
        return out
    }
}

enum JSONSchemaRender {

    static func schema(for type: TypeDescriptor, rules: [Rule]) -> JSONSchemaValue {
        var out: [(String, JSONSchemaValue)] = []

        switch type {
        case .string:
            out.append(("type", .string("string")))
        case .integer:
            out.append(("type", .string("integer")))
        case .number:
            out.append(("type", .string("number")))
        case .boolean:
            out.append(("type", .string("boolean")))
        case .date(let numeric):
            if numeric {
                // `.unixSeconds` and friends arrive as a number. Calling that `date-time`
                // would be false, and a client generating an ISO-8601 string from it would
                // produce a document this type rejects.
                out.append(("type", .string("number")))
                out.append(("description", .string("seconds since the Unix epoch")))
            } else {
                out.append(("type", .string("string")))
                out.append(("format", .string("date-time")))
            }
        case .array(let element):
            out.append(("type", .string("array")))
            // `.each` rules belong on the ELEMENT, which is where JSON Schema puts them too.
            let elementRules = rules.flatMap { r -> [Rule] in
                if case .each(let inner) = r.kind { return inner }
                return []
            }
            out.append(("items", schema(for: element, rules: elementRules)))
        case .dictionary(let value):
            out.append(("type", .string("object")))
            out.append(("additionalProperties", schema(for: value, rules: [])))
        case .optional(let wrapped):
            // 2020-12 spells nullability as a type union. An optional field is ALSO absent-able,
            // which is expressed by leaving it out of `required` rather than here.
            var inner = schema(for: wrapped, rules: rules)
            if case .object(var members) = inner,
               let i = members.firstIndex(where: { $0.0 == "type" }),
               case .string(let t) = members[i].1 {
                members[i] = ("type", .array([.string(t), .string("null")]))
                inner = .object(members)
            }
            return inner
        case .nested(let meta):
            // Inline rather than `$ref` + `$defs`. A `$ref` needs a document-wide definition
            // table, which needs the whole graph walked and deduplicated, and a cycle in that
            // graph is representable in Swift and not detectable from one descriptor. Inlining
            // is correct for every acyclic schema and is what a reader wants to see; a
            // recursive type is refused at expansion rather than rendered wrongly.
            return .object(meta._assaySchemaDescriptor.body(for: .input, includeDialect: false))
        case .opaque:
            // Any value. Deliberately not narrowed — see the file header.
            return .object([])
        }

        out.append(contentsOf: keywords(for: rules, on: type))
        return .object(out)
    }

    /// Rule -> keyword, given the field's declared type. See the file header for what is
    /// deliberately dropped, and why dropping beats approximating.
    static func keywords(for rules: [Rule], on type: TypeDescriptor) -> [(String, JSONSchemaValue)] {
        var out: [(String, JSONSchemaValue)] = []
        var notes: [String] = []

        func isString() -> Bool { if case .string = type { return true }; return false }
        func isArray() -> Bool { if case .array = type { return true }; return false }

        for rule in rules {
            switch rule.kind {
            case .min(let v):
                if isString() { out.append(("minLength", .number(v))) }
                else if isArray() { out.append(("minItems", .number(v))) }
                else { out.append(("minimum", .number(v))) }
            case .max(let v):
                if isString() { out.append(("maxLength", .number(v))) }
                else if isArray() { out.append(("maxItems", .number(v))) }
                else { out.append(("maximum", .number(v))) }
            case .range(let lo, let hi):
                if isString() {
                    out.append(("minLength", .number(lo)))
                    out.append(("maxLength", .number(hi)))
                } else if isArray() {
                    out.append(("minItems", .number(lo)))
                    out.append(("maxItems", .number(hi)))
                } else {
                    out.append(("minimum", .number(lo)))
                    out.append(("maximum", .number(hi)))
                }
            case .length(let n):
                out.append(("minLength", .number(Double(n))))
                out.append(("maxLength", .number(Double(n))))
            case .notEmpty:
                if isArray() { out.append(("minItems", .number(1))) }
                else { out.append(("minLength", .number(1))) }
            case .count(let lo, let hi):
                out.append(("minItems", .number(Double(lo))))
                out.append(("maxItems", .number(Double(hi))))
            case .unique:
                out.append(("uniqueItems", .bool(true)))
            case .regex(let p):
                // ECMA-262 is what 2020-12's `pattern` specifies, and Swift's `Regex` is not
                // that dialect. The pattern is emitted as written because it is right far more
                // often than not, and the alternative — dropping it — under-documents a real
                // constraint. Noted so a consumer knows to check.
                out.append(("pattern", .string(p.pattern)))
            case .email:    out.append(("format", .string("email")))
            case .url:      out.append(("format", .string("uri")))
            case .uuid:     out.append(("format", .string("uuid")))
            case .hostname: out.append(("format", .string("hostname")))
            case .ascii:    out.append(("pattern", .string("^[\\u0000-\\u007F]*$")))
            case .prefix(let s):   out.append(("pattern", .string("^" + escaped(s))))
            case .suffix(let s):   out.append(("pattern", .string(escaped(s) + "$")))
            case .contains(let s): out.append(("pattern", .string(escaped(s))))
            case .oneOf(let values):
                out.append(("enum", .array(values.map { .string($0) })))
            case .positive:     out.append(("exclusiveMinimum", .number(0)))
            case .negative:     out.append(("exclusiveMaximum", .number(0)))
            case .nonNegative:  out.append(("minimum", .number(0)))
            case .multipleOf(let v): out.append(("multipleOf", .number(v)))
            case .finite:
                // JSON has no infinities to exclude, so this constrains nothing on the wire.
                break
            case .all(let inner):
                out.append(contentsOf: keywords(for: inner, on: type))
            case .each:
                // Rendered on `items` by the array case. Nothing to add at this level.
                break
            case .before(_, let bound):
                notes.append("must be before \(bound)")
            case .after(_, let bound):
                notes.append("must be after \(bound)")
            case .betweenDates(_, _, let lo, let hi):
                notes.append("must be between \(lo) and \(hi)")
            case .trimmed:
                // An assertion, but one no `pattern` expresses exactly. See the file header.
                notes.append("must have no leading or trailing whitespace")
            case .lowercased:
                notes.append("must be lowercase")
            case .messageOnly, .invalidRuleDate:
                break
            }
        }

        // Constraints with no exact 2020-12 keyword, recorded in prose rather than dropped
        // silently or rendered with a keyword that might be narrower than the real check.
        if !notes.isEmpty {
            out.append(("description", .string(notes.joined(separator: "; "))))
        }
        return out
    }

    /// Escape a literal for use inside a `pattern`.
    static func escaped(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\^$.|?*+()[]{}".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

/// A minimal JSON value for rendering schema documents.
///
/// **Deliberately not `JSON.Value`**, which lives in `Assay` rather than `AssayCore` and
/// whose object case is a `[String: JSON.Value]` dictionary. A JSON Schema's key order is
/// meaningful to a human reading it — `type` before `properties` before `required` — and a
/// dictionary would scramble it on every render. Member order here is declaration order.
public indirect enum JSONSchemaValue: Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONSchemaValue])
    case object([(String, JSONSchemaValue)])

    /// Pretty-printed, two-space indent, stable member order.
    public func text(indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        switch self {
        case .string(let s):  return "\"\(JSONSchemaValue.escapeJSON(s))\""
        case .bool(let b):    return b ? "true" : "false"
        case .number(let d):
            if d == d.rounded() && d.magnitude < 1e15 {
                return String(Int64(d))
            }
            return String(d)
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let body = items.map { inner + $0.text(indent: indent + 2) }
                .joined(separator: ",\n")
            return "[\n" + body + "\n" + pad + "]"
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let body = members.map {
                inner + "\"\(JSONSchemaValue.escapeJSON($0.0))\": " + $0.1.text(indent: indent + 2)
            }.joined(separator: ",\n")
            return "{\n" + body + "\n" + pad + "}"
        }
    }

    static func escapeJSON(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            case "\t":  out += "\\t"
            default:
                if scalar.value < 0x20 {
                    // No Foundation in AssayCore, so no `String(format:)`. Control bytes are
                    // vanishingly rare in a schema's titles and patterns; correctness here
                    // matters and speed does not.
                    let hex = "0123456789abcdef"
                    let digits = Array(hex.unicodeScalars)
                    out += "\\u00"
                    out.unicodeScalars.append(digits[Int((scalar.value >> 4) & 0xF)])
                    out.unicodeScalars.append(digits[Int(scalar.value & 0xF)])
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}

extension SchemaDescribing {
    /// The JSON Schema 2020-12 document for this type. `EXPERIENCE.md` §14.
    public static func jsonSchema(for face: SchemaFace = .input) -> JSONSchemaValue {
        _assaySchemaDescriptor.jsonSchema(for: face)
    }

    /// The same document as text, ready to write to a file or paste into an OpenAPI spec.
    public static func jsonSchemaText(for face: SchemaFace = .input) -> String {
        jsonSchema(for: face).text()
    }
}
