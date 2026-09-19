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
// MEASURED 2026-09-10, because the paragraph above went unmeasured for a month: the code
// roughly doubles and the compile time does NOT follow it — `encodes: true` costs about 5%
// (82.2 ms/type against 78.0 at 10 fields). The body is the cheapest shape the type checker
// sees: one concrete `w.write(self.x)` per field, nothing to infer. Opt-in stays, because 5%
// across a model layer is real; "it would double your build" was never the number.
// docs/COMPILE-TIME.md §5.6.
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

        // THE MEMBERS ARE A SEPARATE FUNCTION, and the reason is a union.
        //
        // `docs/UNIONS.md` §4: a discriminated union writes "the payload's object with the
        // tag added". The payload is a token to the macro, so the union cannot write the
        // payload's fields itself — and if the payload writes its own braces there is
        // nowhere left to put the tag. Splitting the braces off gives the union a seam:
        // open the object, write the tag, let the variant write its members into it.
        //
        // The alternative was byte surgery — let the variant write `{...}`, pop the closing
        // brace back off the buffer and append the tag. That costs nothing at compile time
        // and puts the tag LAST, and it was rejected: it makes the writer's output depend on
        // reaching into bytes it has already emitted, and every future writer change has to
        // keep that reachable. This costs one three-line wrapper per encoding type — constant,
        // not per-field, which is the term `docs/COMPILE-TIME.md` says actually matters.
        body += """
        nonisolated public func _assayEncodeMembers(
            into w: inout Assay.JSONWriter,
            into sink: inout Assay.IssueSink,
            at path: inout [Assay.PathComponent]
        ) {
        \(lines)}

        nonisolated public func _assayEncode(
            into w: inout Assay.JSONWriter,
            into sink: inout Assay.IssueSink,
            at path: inout [Assay.PathComponent]
        ) {
            w.beginObject()
            self._assayEncodeMembers(into: &w, into: &sink, at: &path)
            w.endObject()
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
        \(pad)\(keyStatement(segment))
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
                    \(keyStatement(key))
                    if let __e\(i) = \(value) {
            \(writeCall(base, "__e\(i)", key: key, index: i, indent: 12))
                    } else {
                        w.writeNull()
                    }

            """
        }
        return """
                \(keyStatement(key))
        \(writeCall(base, value, key: key, index: i, indent: 8))

        """
    }

    /// The expression that writes one non-optional value of `type`.
    /// The statement that writes a static key. For an ordinary key it is ONE append of the
    /// key's complete JSON text (`"name":`) through `JSONWriter._key(encoded:)`, instead of one
    /// append per byte. That applies only when the key's spelling IS its value and needs no
    /// JSON escaping: no backslash, no quote, no control character. The macro sees a key as
    /// its Swift SOURCE spelling (`we\"ird`, backslash included), so any key with an escape in
    /// it keeps `w.key("…")`, which re-embeds the spelling in a literal and escapes the value
    /// at run time. A first version escaped the spelling itself and double-escaped such keys;
    /// `EncodingTests.oddKeys` caught it.
    static func keyStatement(_ key: String) -> String {
        let plain = key.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0 != "\"" && $0 != "\\" }
        return plain ? "w._key(encoded: \"\\\"\(key)\\\":\")" : "w.key(\"\(key)\")"
    }

    static func writeCall(
        _ type: String, _ expr: String, key: String, index i: Int, indent: Int,
        /// The path a NESTED schema value is encoded at, when the caller has one ready —
        /// an array element's `__ep` below. nil means `path + [.key(key)]`.
        nestedPath: String? = nil
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
            // ONE PATH PER ARRAY, rewritten in place — the decode side's 2026-09-13 fix,
            // which this side never got. Until 2026-09-19 a nested-schema element was encoded
            // `at: path + [.key(k)]` INSIDE the loop: one heap allocation per element (2,000
            // per `base/encode` call, all of its per-element blocks), and no `.index(n)`, so
            // an issue in element 7 was reported at `items` rather than `items[7]`. The path
            // is read only when something fails; rewriting its last component keeps the
            // buffer uniquely referenced, so the happy path copies nothing.
            let ep = "__ep\(i)_\(indent)", n = "__en\(i)_\(indent)"
            let body = writeCall(element, "__a\(i)", key: key, index: i, indent: indent + 4,
                                 nestedPath: ep)
            guard body.containsSubstring(ep) else {
                return """
                \(pad)w.beginArray()
                \(pad)for __a\(i) in \(expr) {
                \(body)
                \(pad)}
                \(pad)w.endArray()
                """
            }
            return """
            \(pad)w.beginArray()
            \(pad)var \(ep) = path
            \(pad)\(ep).append(.key("\(key)"))
            \(pad)\(ep).append(.index(0))
            \(pad)var \(n) = 0
            \(pad)for __a\(i) in \(expr) {
            \(pad)    \(ep)[\(ep).count &- 1] = .index(\(n))
            \(pad)    \(n) &+= 1
            \(body)
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
            // The path is `inout` (see `JSONEncodableSchema`): an array element passes its
            // per-array path by reference, and anything else pushes the key, calls, and pops,
            // instead of allocating `path + [.key(k)]` per nested value per element.
            if let nestedPath {
                return "\(pad)\(expr)._assayEncode(into: &w, into: &sink, at: &\(nestedPath))"
            }
            return """
            \(pad)path.append(.key("\(key)"))
            \(pad)\(expr)._assayEncode(into: &w, into: &sink, at: &path)
            \(pad)path.removeLast()
            """
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
