// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Emitting the JSON encode body. docs/ENCODING.md.
//
// OPT-IN, and that is a compile-time decision rather than a taste one. Body size is what
// dominates @Schema's expansion cost (docs/COMPILE-TIME.md), so emitting an encoder for
// every type would roughly double the per-field code every user pays for, whether or not
// they encode. `@Schema(encodes: true)` means a type that only decodes costs exactly what
// it costs today.
//
// The semantics implemented here are docs/ENCODING.md's six answers, each marked at the
// site that implements it:
//
//   Q1 @Fallback writes its value like any other field — decode-time-only attribute.
//   Q3 @Transform requires a paired @Inverse, checked at EXPANSION.
//   Q4 issues go to the shared IssueSink with a path and no location.
//   Q5 the encoder targets `.input`: it writes the document `parse` accepts.
//   Q6 defaults are always emitted; @Extras is written back, collisions are an error.
//===----------------------------------------------------------------------===//

extension SchemaMacro {

    /// Q6: the declared wire keys, so an @Extras key that collides with one can be
    /// reported rather than silently producing a duplicate key or dropping data. Emitted
    /// once, whichever encode bodies exist.
    static func declaredKeys(_ fields: [SchemaField], _ extras: SchemaField?) -> String {
        guard extras != nil else { return "" }
        let names = fields.map { "\"\($0.wireKey)\"" }.joined(separator: ", ")
        return """
        nonisolated static let __assayDeclaredKeys: Set<String> = [\(names)]


        """
    }

    static func encodeBody(
        typeName: String,
        fields: [SchemaField],
        extras: SchemaField?
    ) -> String {
        var body = ""

        var lines = ""
        for (i, f) in fields.enumerated() {
            lines += encodeStatement(field: f, index: i)
        }

        if let e = extras {
            // Q6: written back. Collecting unknown keys and then dropping them on the way
            // out is the one behaviour that makes @Extras actively harmful — a proxy that
            // decodes, edits and re-encodes would silently delete everything it did not
            // recognise.
            lines += """
                    for __x in self.\(e.identifier) {
                        if Self.__assayDeclaredKeys.contains(__x.key) {
                            sink.add(Assay.Issue(
                                code: .extrasKeyCollision,
                                path: path + [.key(__x.key)],
                                params: ["key": .string(__x.key)]))
                            continue
                        }
                        w.key(__x.key)
                        w.write(__x.value, &sink, path + [.key(__x.key)], "")
                    }

            """
        }

        body += """
        nonisolated public func _assayEncode(
            into w: inout Assay.JSONWriter,
            into sink: inout Assay.IssueSink,
            at path: [Assay.PathComponent]
        ) {
            w.beginObject()
        \(lines)    w.endObject()
        }
        """
        return body
    }

    /// One line per field, mirroring the decode bodies' discipline.
    static func encodeStatement(field f: SchemaField, index i: Int) -> String {
        let key = f.wireKey
        let base = f.decodedType

        // Q3: a transformed field encodes through its inverse, back to the WIRE type —
        // which is what makes Q5's round-trip law hold. The expansion-time check in
        // checkEncodable guarantees the inverse exists by the time this runs.
        let value = f.transform != nil
            ? "Self.__assayInverse_\(i)(self.\(f.identifier))"
            : "self.\(f.identifier)"

        if f.isOptional {
            // An absent optional writes an explicit null: `nil` decoded from either an
            // absent key or a null, and null is the form that round-trips through both.
            return """
                    w.key("\(key)")
                    if let __e\(i) = \(value) {
            \(writeCall(base, "__e\(i)", key: key, index: i, indent: 12))
                    } else {
                        w.writeNull()
                    }

            """
        }
        return """
                w.key("\(key)")
        \(writeCall(base, value, key: key, index: i, indent: 8))

        """
    }

    /// The expression that writes one non-optional value of `type`.
    static func writeCall(
        _ type: String, _ expr: String, key: String, index i: Int, indent: Int
    ) -> String {
        let pad = String(repeating: " ", count: indent)

        if isDateType(type) {
            let formats = dateFormatsRef(SchemaField(
                identifier: "", typeName: type, wireKey: key, aliases: [], isOptional: false,
                defaultExpr: nil, isIgnored: false, isExtras: false, coerce: false,
                dateFormats: nil), i)
            _ = formats
            return "\(pad)w.writeDate(\(expr).timeIntervalSince1970, \(dateFormatsExpr(i)), &sink, path, \"\(key)\")"
        }
        if let element = arrayElement(type) {
            return """
            \(pad)w.beginArray()
            \(pad)for __a\(i) in \(expr) {
            \(writeCall(element, "__a\(i)", key: key, index: i, indent: indent + 4))
            \(pad)}
            \(pad)w.endArray()
            """
        }
        if let valueType = dictionaryValue(type) {
            // Sorted, so encoding is deterministic: a Dictionary has no order, and a
            // decoder that produced a different byte sequence on every run would make the
            // round-trip law in docs/ENCODING.md §5 untestable.
            return """
            \(pad)w.beginObject()
            \(pad)for __k\(i) in \(expr).keys.sorted() {
            \(pad)    w.key(__k\(i))
            \(writeCall(valueType, "\(expr)[__k\(i)]!", key: key, index: i, indent: indent + 4))
            \(pad)}
            \(pad)w.endObject()
            """
        }
        switch type {
        case "String", "Bool", "Int", "Int64", "Int32", "UInt",
             "Int8", "Int16", "UInt8", "UInt16", "UInt32", "UInt64":
            return "\(pad)w.write(\(expr))"
        case "Double", "Float":
            // Q4: NaN and infinity have no JSON spelling, so these take the sink.
            return "\(pad)w.write(\(expr), &sink, path, \"\(key)\")"
        case "RawValue", "Assay.RawValue", "JSON.Value", "Assay.JSON.Value":
            return "\(pad)w.write(\(expr), &sink, path, \"\(key)\")"
        default:
            // A nested @Schema type. Its own `encodes: true` is enforced by the compiler:
            // without it there is no `_assayEncode` to call, and the error names the type.
            return "\(pad)\(expr)._assayEncode(into: &w, into: &sink, at: path + [.key(\"\(key)\")])"
        }
    }

    static func dateFormatsExpr(_ i: Int) -> String {
        "Self.__assayDateFormats_\(i)"
    }

    /// The `@Inverse` closures, emitted beside the `@Transform` ones.
    static func inverseClosures(_ fields: [SchemaField]) -> String {
        var out = ""
        for (i, f) in fields.enumerated() {
            guard let inv = f.inverse, let t = f.transform else { continue }
            let output = stripOptional(f.typeName)
            out += """
            nonisolated static let __assayInverse_\(i): @Sendable (\(output)) -> \(t.wireType) = \(inv)

            """
        }
        return out
    }

    /// Q3, at expansion: a transformed field with no inverse cannot be encoded, and the
    /// diagnostic says so where the user can act on it rather than inside generated code.
    ///
    /// This is the same shape as the `@Validate` rule/type check and the `@DateFormat`
    /// pattern check — the macro can see both the attribute and the declared types, so it
    /// refuses at compile time instead of at runtime.
    static func encodeDiagnostics(_ fields: [SchemaField]) -> [String] {
        var out: [String] = []
        for f in fields {
            if let t = f.transform, f.inverse == nil {
                out.append(
                    "'\(f.identifier)' has a @Transform but no @Inverse, so this type "
                    + "cannot be encoded; add "
                    + "@Inverse({ (v: \(stripOptional(f.typeName))) in /* -> \(t.wireType) */ }), "
                    + "or remove `encodes: true`")
            }
            if f.inverse != nil, f.transform == nil {
                out.append(
                    "'\(f.identifier)' has an @Inverse but no @Transform; the inverse "
                    + "would never run")
            }
        }
        return out
    }
}
