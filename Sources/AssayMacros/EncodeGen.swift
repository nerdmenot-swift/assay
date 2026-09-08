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
    /// The keys `@Extras` must not collide with, which are the keys this type writes at the
    /// TOP level — so a path group contributes its first segment, not its leaf.
    static func declaredKeys(
        _ fields: [SchemaField], _ extras: SchemaField?, groups: [PathGroup] = []
    ) -> String {
        guard extras != nil else { return "" }
        let names = (fields.filter { $0.pathSegments == nil }.map(\.wireKey)
                     + groups.map(\.segment))
            .map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        nonisolated static let __assayDeclaredKeys: Set<String> = [\(names)]


        """
    }

    static func encodeBody(
        typeName: String,
        fields: [SchemaField],
        extras: SchemaField?,
        groups: [PathGroup] = []
    ) -> String {
        var body = ""

        var lines = ""
        for (i, f) in fields.enumerated() where f.pathSegments == nil {
            lines += encodeStatement(field: f, index: i)
        }
        // `@Key(path:)`. Two fields under one prefix write ONE object, which is the whole
        // reason the encoder cannot just emit a dotted key: `{"profile.name": ...}` is a
        // different document from `{"profile": {"name": ...}}`, and only the second one this
        // schema can read back. `docs/ENCODING.md`'s round-trip law is what forces the merge.
        for g in groups {
            lines += encodePathNode(g.node, fields: fields, segment: g.segment, indent: 8)
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
    /// One nested object per path node, recursively.
    static func encodePathNode(
        _ n: PathNode, fields: [SchemaField], segment: String, indent: Int
    ) -> String {
        let pad = String(repeating: " ", count: indent)
        var inner = ""
        for (seg, i) in n.leaves {
            // The field's key inside this object is its LAST segment, which `wireKey`
            // already is — the parser set it there so every message naming a key names the
            // one actually looked for.
            _ = seg
            inner += reindent(encodeStatement(field: fields[i], index: i), by: indent - 4)
        }
        for (seg, child) in n.children {
            inner += encodePathNode(child, fields: fields, segment: seg, indent: indent + 4)
        }
        return """
        \(pad)w.key("\(segment)")
        \(pad)w.beginObject()
        \(inner)\(pad)w.endObject()

        """
    }

    /// Shift generated lines right, so a nested object's contents sit under it. Cheaper
    /// than an `indent:` parameter on every emitter, which would have to thread through
    /// `writeCall` and its four type shapes to say something purely cosmetic.
    static func reindent(_ text: String, by n: Int) -> String {
        guard n > 0 else { return text }
        let pad = String(repeating: " ", count: n)
        var out = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            out += line.isEmpty ? "\n" : pad + line + "\n"
        }
        if out.hasSuffix("\n") && !text.hasSuffix("\n") { out.removeLast() }
        return out
    }

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
