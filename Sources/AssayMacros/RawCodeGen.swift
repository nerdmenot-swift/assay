// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The second generated body: decoding from RawValue, for YAML and XML.
//
// This is the DOM path. It is deliberately NOT how JSON decodes — see
// AssayCore/RawDecode.swift for why the hop is accepted for YAML and XML and refused for
// JSON.
//
// Two constraints from the JSON body carry over unchanged:
//
//   * **Never `switch` over a `String`.** It lowers to `_findStringSwitchCase`, a literal
//     O(n) linear scan with a full `String ==` per case. So key dispatch here buckets by
//     `key.utf8.count` first — an integer switch, which experiment #1 measured reaching a
//     jump table at N >= 10 and a balanced binary search below it.
//
//   * **One line of generated code per field**, with everything conditional living in an
//     `@inlinable` runtime helper. docs/COMPILE-TIME.md §3 rule 2: body size is what
//     dominates expansion cost, and this file doubles the number of bodies, so it has to
//     be at least as disciplined as the first.
//===----------------------------------------------------------------------===//

extension SchemaMacro {

    static func rawDecodeBody(
        typeName: String,
        fields: [SchemaField],
        extras: SchemaField?,
        policy: String,
        ordered: [SchemaField]?,
        emitKnownKeys: Bool = false,
        validation: String = "",
        checks: String = "",
        /// `@Key(path:)` groups. See `PathKeys.swift`.
        groups: [PathGroup] = [],
        /// The `@Schema(context:)` type name, or `""`. See `CodeGen.decodeBody`.
        ctx: String = ""
    ) -> String {
        let ctxParam = ctx.isEmpty ? "" : ",\n            context: \(ctx)"

        var prefix = ""
        if emitKnownKeys, policy == "warn" || policy == "reject" {
            let names =
                (fields.filter { $0.pathSegments == nil }
                .flatMap { [$0.wireKey] + $0.aliases }
                + groups.map(\.segment))
                .map { "\"\($0)\"" }.joined(separator: ", ")
            prefix = """
                nonisolated static let __assayKnownKeys: [String] = [\(names)]


                """
        }

        var locals = ""
        var requiredMask: UInt64 = 0
        // A span local per field that can report one, mirroring the JSON body. On this path
        // the span comes from `RawValue.Member`, which the YAML and XML parsers fill in;
        // it is nil for any producer that does not track offsets, and nil is always safe.
        for (i, f) in fields.enumerated() where rawNeedsSpan(f) {
            locals += "    var __sp\(i): Assay.SourceSpan? = nil\n"
        }
        for (i, f) in fields.enumerated() {
            locals += "    var __f\(i): \(f.decodedType)? = \(f.defaultExpr ?? "nil")\n"
            // XML's repeated siblings arrive one call each; this counts them, failed ones
            // included, so `<tag>` number three is `tag[2]` whatever happened to one and two.
            if arrayElement(f.decodedType) != nil, f.xmlPlacement != "wrapped" {
                locals += "    var __n\(i) = 0\n"
            }
            if !f.isOptional && f.defaultExpr == nil && f.fallback == nil {
                requiredMask |= (1 << UInt64(i))
            }
        }
        if let e = extras {
            locals +=
                "    \(policy == "collect" ? "var" : "let") __extras: \(stripOptional(e.typeName)) = [:]\n"
        }

        // Bucket by key length, then compare within the bucket.
        var byLength: [Int: [(Int, SchemaField, String)]] = [:]
        for (i, f) in fields.enumerated() where f.pathSegments == nil {
            // An `@XML(.text)` field reads the element's own character data, which the
            // XML projection stores under a reserved EMPTY key — it has no name of its
            // own in the document. It is matched as an extra alias rather than a
            // replacement, so the same field still reads a normally-named key from YAML,
            // where character data is not a concept.
            let extra = f.xmlPlacement == "text" ? [""] : []
            for key in [f.wireKey] + f.aliases + extra {
                byLength[key.utf8.count, default: []].append((i, f, key))
            }
        }

        var arms = ""
        for len in byLength.keys.sorted() {
            var checks = ""
            var first = true
            for (i, f, key) in byLength[len]! {
                checks += "\(first ? "" : " else ")if __k == \"\(key)\" {\n"
                checks += "                    __presence |= \(presenceBit(i))\n"
                if key != f.wireKey, !key.isEmpty {
                    checks +=
                        "                    Assay._assayAliasMatched(&sink, path, \"\(f.wireKey)\", \"\(key)\")\n"
                }
                if rawNeedsSpan(f) {
                    checks += "                    __sp\(i) = __m.span\n"
                }
                checks +=
                    "                    \(rawDecodeStatement(field: f, index: i, ctx: ctx))\n"
                checks += "                }"
                first = false
            }
            checks +=
                " else {\n                    \(rawUnknownArm(policy: policy, extras: extras, segments: groups.map(\.segment)))\n                }"
            arms += """
                            case \(len):
                                \(checks)

                """
        }

        var missing = ""
        for (i, f) in fields.enumerated()
        where f.pathSegments == nil && (requiredMask & (1 << UInt64(i))) != 0 {
            missing += """
                        if __presence & \(presenceBit(i)) == 0 {
                            Assay.RawValue._missing(&sink, path, "\(f.wireKey)")
                        }

                """
        }
        missing = rawPathPresence(groups, fields: fields, indent: 8) + missing

        var indexOf: [String: Int] = [:]
        for (i, f) in fields.enumerated() { indexOf[f.identifier] = i }
        let args = Self.constructionArgs(fields: fields, ordered: ordered, indexOf: indexOf)
        var unwraps = ""
        for (i, f) in fields.enumerated() where !f.isOptional {
            unwraps += "        guard let __v\(i) = __f\(i) else { return nil }\n"
        }

        let requires =
            ctx.isEmpty
            ? nestedNominalTypes(fields).map { "    Assay._assayRequireRaw(\($0).self)\n" }.joined()
            : ""
        return prefix + """
            nonisolated public static func _assay(
                from raw: Assay.RawValue,
                into sink: inout Assay.IssueSink,
                at path: inout [Assay.PathStep]\(ctxParam)
            ) -> \(typeName)? {
            \(requires)    guard case .mapping(let __members) = raw else {
                    Assay.RawValue._notAnObject(&sink, path, raw)
                    return nil
                }
                // See the note in the JSON body: local validity, not global.
                let __ck0 = sink.checkpoint()

            \(locals)    var __presence: UInt64 = 0\(groups.isEmpty ? "" : "\n    var __gpresence: UInt64 = 0")

            \(rawPathDescent(groups, fields: fields, ctx: ctx))    for __m in __members {
                    let __k = __m.key
                    let __v = __m.value
                    switch __k.utf8.count {
            \(arms)            default:
                        \(rawUnknownArm(policy: policy, extras: extras, segments: groups.map(\.segment)))
                    }
                }

            \(missing)
            \(validation)
            \(unwraps)    let __result = \(typeName)(\(args.joined(separator: ", ")))
            \(checks)
                guard sink.checkpoint() == __ck0 else { return nil }
                return __result
            }
            """
    }

    /// `segments` are the first components of every `@Key(path:)` group. A key the
    /// schema reached THROUGH is not an unknown key, and the JSON body has always known
    /// that — its dispatch table has an arm for the prefix, so the key is consumed before
    /// the unknown handler sees it. This body descends into paths separately, so without
    /// this the same document put `profile` into `@Extras` on YAML/XML/TOML and not on
    /// JSON. Found 2026-09-11 by showing the same example in TOML.
    static func rawUnknownArm(
        policy: String, extras: SchemaField?,
        segments: [String] = []
    ) -> String {
        switch policy {
        case "collect":
            guard let e = extras else { return "break" }
            let value = elementType(stripOptional(e.typeName))
            // RawValue is the only thing a RawValue-shaped decode can produce, so a
            // format-specific extras type is simply not reachable on this path.
            guard value.hasSuffix("RawValue") else { return "break" }
            if segments.isEmpty { return "__extras[__k] = __v" }
            let list = segments.map { "\"\($0)\"" }.joined(separator: ", ")
            return "if ![\(list)].contains(__k) { __extras[__k] = __v }"
        case "warn":
            return
                "Assay.RawValue._unknownKey(&sink, path, __k, known: Self.__assayKnownKeys, reject: false, span: __m.span)"
        case "reject":
            return
                "Assay.RawValue._unknownKey(&sink, path, __k, known: Self.__assayKnownKeys, reject: true, span: __m.span)"
        default:
            return "break"
        }
    }

    /// One line per field, mirroring the JSON body's discipline.
    static func rawDecodeStatement(
        field f: SchemaField, index i: Int,
        ctx: String = ""
    ) -> String {
        let ctxArg = ctx.isEmpty ? "" : ", context: context"
        let base = f.decodedType
        let key = f.wireKey

        // Date — same seam as the JSON body: the runtime returns epoch seconds, the
        // wrap resolves in the user's module. YAML's resolved `.int` scalars and XML's
        // text both reach the format list through `assayDate`.
        if isDateType(base) {
            let formats = dateFormatsRef(f, i)
            let wrap = ".map { \(base)(timeIntervalSince1970: $0) }"
            if f.fallback != nil {
                return """
                    let __fck\(i) = sink.checkpoint()
                                    if !__v.isNull { __f\(i) = __v._assayDate(&sink, path, "\(key)", \(formats))\(wrap) }
                                    if __f\(i) == nil { sink.rollback(to: __fck\(i)) }
                    """
            }
            if f.isOptional {
                return
                    "if !__v.isNull { __f\(i) = __v._assayDate(&sink, path, \"\(key)\", \(formats))\(wrap) }"
            }
            return "__f\(i) = __v._assayDate(&sink, path, \"\(key)\", \(formats))\(wrap)"
        }

        let spanRef = rawNeedsSpan(f) ? "__sp\(i)" : nil
        if f.fallback != nil,
            let call = rawScalarCall(base, key: key, coerce: f.coerce, span: spanRef)
        {
            return """
                let __fck\(i) = sink.checkpoint()
                                if !__v.isNull { __f\(i) = __v.\(call) }
                                if __f\(i) == nil { sink.rollback(to: __fck\(i)) }
                """
        }

        // Arrays. Three wire shapes reach this path and they are NOT interchangeable, so
        // the placement decided at compile time picks which are accepted:
        //
        //   `.sequence`            YAML's `tags: [a, b]`. Always accepted.
        //   repeated members       XML's `<tag>a</tag><tag>b</tag>` — the default. Each
        //                          sibling arrives as its OWN call with the same key, so
        //                          this arm appends rather than assigns.
        //   `.mapping` of entries  XML's `@XML(.wrapped)` form. Accepted ONLY when the
        //                          field asked for it, because it is genuinely ambiguous
        //                          otherwise: `<items><id>1</id><name>x</name></items>` is
        //                          one struct, not two values, and nothing in the document
        //                          distinguishes that from a wrapper.
        if let element = arrayElement(base) {
            let seqExpr = rawFieldExpr(
                base, "__v", key: key, coerce: f.coerce,
                dateFormatsRef: dateFormatsRef(f, i), ctx: ctx)
            if f.xmlPlacement == "wrapped" {
                let wrappedExpr = rawIndexedExpr(
                    element, "__wmm\(i).value", key: key,
                    index: "__wi\(i)", coerce: f.coerce,
                    dateFormatsRef: dateFormatsRef(f, i), ctx: ctx)
                return """
                    if let __r = \(seqExpr) {
                                        __f\(i) = __r
                                    } else if case .mapping(let __wm\(i)) = __v {
                                        __f\(i) = __wm\(i).enumerated().compactMap { (__wi\(i), __wmm\(i)) in
                                            \(wrappedExpr)
                                        }
                                    } else if __v.isNull {
                                        \(f.isOptional ? "__f\(i) = nil" : "__f\(i) = []")
                                    } else if case .string(let __ws\(i)) = __v, __ws\(i).isEmpty {
                                        // `<tags/>` — a childless wrapper projects to empty
                                        // text, and empty is exactly what it means. This is
                                        // the case .wrapped exists for: absent stays absent.
                                        __f\(i) = []
                                    }
                    """
            }
            return """
                if let __r = \(seqExpr) {
                                    __f\(i) = __r
                                } else if __v.isNull {
                                    \(f.isOptional
                                    ? "__f\(i) = nil"
                                    : "Assay.RawValue._mismatchPublic(&sink, path, \"\(key)\", \"array\", __v)")
                                } else {
                                    // One repeated sibling. Append, so `<tag>a</tag><tag>b</tag>`
                                    // accumulates across calls instead of the last one winning;
                                    // its index is how many siblings came before it.
                                    let __ix\(i) = __n\(i)
                                    __n\(i) &+= 1
                                    if let __one\(i) = \(rawIndexedExpr(element, "__v", key: key,
                                                                    index: "__ix\(i)", coerce: f.coerce,
                                                                    dateFormatsRef: dateFormatsRef(f, i), ctx: ctx)) {
                                        if __f\(i) == nil { __f\(i) = [] }
                                        __f\(i)?.append(__one\(i))
                                    }
                                }
                """
        }

        if dictionaryValue(base) != nil {
            return """
                if let __r = \(rawFieldExpr(base, "__v", key: key, coerce: f.coerce,
                                        dateFormatsRef: dateFormatsRef(f, i), ctx: ctx)) {
                                    __f\(i) = __r
                                } else if __v.isNull {
                                    \(f.isOptional
                                    ? "__f\(i) = nil"
                                    : "Assay.RawValue._mismatchPublic(&sink, path, \"\(key)\", \"object\", __v)")
                                }
                """
        }

        if let call = rawScalarCall(base, key: key, coerce: f.coerce, span: spanRef) {
            if f.isOptional {
                return "if !__v.isNull { __f\(i) = __v.\(call) }"
            }
            return "__f\(i) = __v.\(call)"
        }

        // An open value model as a declared field: on this path a RawValue member IS the
        // value, so there is nothing to decode.
        if base == "RawValue" || base == "Assay.RawValue" {
            return f.isOptional ? "if !__v.isNull { __f\(i) = __v }" : "__f\(i) = __v"
        }

        // Nested @Schema type.
        return """
            if __v.isNull {
                                \(f.isOptional
                                ? "__f\(i) = nil"
                                : "Assay.RawValue._mismatchPublic(&sink, path, \"\(key)\", \"\(base)\", __v)")
                            } else {
                                path.append(.key("\(key)"))
                                __f\(i) = \(base)._assay(from: __v, into: &sink, at: &path\(ctxArg))
                                path.removeLast()
                            }
            """
    }

    /// An expression decoding the RawValue named `v` as `type`, recursing through nested
    /// arrays so `[[Double]]` works on this path exactly as it does on the JSON one —
    /// which it did not, until the kitchen-sink test forced the question.
    ///
    /// compactMap's closure is non-escaping, so using `&sink` inside it is statically
    /// enforced exclusivity, not a box — the constraint from PERFORMANCE.md §7 holds.
    static func rawElementExpr(
        _ type: String, _ v: String, coerce: Bool, depth: Int = 0,
        dateFormatsRef: String = "Assay.DateFormat.defaultFormats", ctx: String = ""
    ) -> String {
        // `path` ALREADY NAMES `v` here: the field pushed its key, and each level below
        // pushes the element's `.index(i)` or the dictionary entry's key, so an issue two
        // levels down reads `items[3].tags[0]` as it does from JSON. It read `items.tags`
        // until 2026-09-19, with no index at all. Scalars are therefore called with an
        // EMPTY key, which `RawValue.keyed` takes to mean "add nothing".
        let ctxArg = ctx.isEmpty ? "" : ", context: context"
        if let element = arrayElement(type) {
            let e = "__e\(depth)"
            return
                "Assay._assaySequence(&path, \(v), { \(e), path in \(rawElementExpr(element, e, coerce: coerce, depth: depth + 1, dateFormatsRef: dateFormatsRef, ctx: ctx)) })"
        }
        if let value = dictionaryValue(type) {
            let e = "__e\(depth)"
            return
                "Assay._assayMapping(&path, \(v), { \(e), path in \(rawElementExpr(value, e, coerce: coerce, depth: depth + 1, dateFormatsRef: dateFormatsRef, ctx: ctx)) })"
        }
        if isDateType(type) {
            return
                "\(v)._assayDate(&sink, path, \"\", \(dateFormatsRef)).map { \(type)(timeIntervalSince1970: $0) }"
        }
        if let call = rawScalarCall(type, key: "", coerce: coerce) {
            return "\(v).\(call)"
        }
        if type == "RawValue" || type == "Assay.RawValue" {
            // The raw path IS RawValue: an open-map value is the member itself.
            return "Optional(\(v))"
        }
        return "\(type)._assay(from: \(v), into: &sink, at: &path\(ctxArg))"
    }

    /// `rawElementExpr` for a FIELD: push its key, then decode with the path naming it.
    /// A parenthesized closure, not a trailing one: these sit in `if let` conditions, where
    /// a trailing closure is a warning in the user's build.
    static func rawFieldExpr(
        _ type: String, _ v: String, key: String, coerce: Bool,
        dateFormatsRef: String, ctx: String
    ) -> String {
        // The collection helpers take the key themselves and push it only once the value
        // has the right shape: an XML repeated sibling reaches this form first and is not
        // a sequence.
        let helper = arrayElement(type) != nil ? "_assaySequence" : "_assayMapping"
        let inner = arrayElement(type) ?? dictionaryValue(type) ?? type
        return
            "Assay.\(helper)(&path, \"\(key)\", \(v), { __e0, path in \(rawElementExpr(inner, "__e0", coerce: coerce, depth: 1, dateFormatsRef: dateFormatsRef, ctx: ctx)) })"
    }

    /// One element of a repeated or wrapped array, at position `index`.
    static func rawIndexedExpr(
        _ type: String, _ v: String, key: String, index: String, coerce: Bool,
        dateFormatsRef: String, ctx: String
    ) -> String {
        "Assay._assayElement(&path, &sink, \"\(key)\", \(index), { path, sink in \(rawElementExpr(type, v, coerce: coerce, dateFormatsRef: dateFormatsRef, ctx: ctx)) })"
    }

    /// `span` is the expression naming this field's captured span, or nil for a position
    /// that has none. Only a top-level mapping member carries one: `RawValue.Member.span`
    /// is where the YAML and XML parsers record an offset, and an element nested inside an
    /// array or dictionary value has no slot of its own. Those decode without a caret, the
    /// same way they do today.
    /// Whether this field's raw-path decode can carry a span.
    ///
    /// `SchemaField.needsSpan` answers "do this field's RULES need somewhere to point",
    /// which is the right question on the JSON path: a decode failure there uses the
    /// reader's own position, so a rule-free field needs no capture and the capture is
    /// real work (`reader.lastValueSpan`).
    ///
    /// On THIS path a decode failure has no reader to ask — the span has to come from
    /// `RawValue.Member.span`, which is already in hand at the match. Tying the capture to
    /// rules meant a type mismatch on a rule-free field printed with no caret in YAML, XML,
    /// TOML and plists while the same mistake in JSON pointed at the byte. Found by writing
    /// the format pages: `enabled: no` reported `enabled must be a boolean, found "no"` and
    /// nothing else.
    ///
    /// Scalars only, and that is not a shortcut: the span is *consumed* by `rawScalarCall`
    /// and by the validation calls, so capturing it for a nested `@Schema` field would
    /// assign a local nothing reads — which is a warning in the user's build, and this
    /// package gates on zero warnings.
    static func rawNeedsSpan(_ f: SchemaField) -> Bool {
        f.needsSpan || rawScalarCall(f.decodedType, key: "", coerce: f.coerce) != nil
    }

    static func rawScalarCall(
        _ type: String, key: String, coerce: Bool, span: String? = nil
    ) -> String? {
        let c = (coerce ? ", coerce: true" : "") + (span.map { ", at: \($0)" } ?? "")
        switch type {
        case "String": return "_assayString(&sink, path, \"\(key)\"\(c))"
        case "Int": return "_assayInt(&sink, path, \"\(key)\"\(c))"
        case "Int64": return "_assayInt64(&sink, path, \"\(key)\"\(c))"
        case "Int32": return "_assayInt32(&sink, path, \"\(key)\"\(c))"
        case "Int8": return "_assayInt8(&sink, path, \"\(key)\"\(c))"
        case "Int16": return "_assayInt16(&sink, path, \"\(key)\"\(c))"
        case "UInt8": return "_assayUInt8(&sink, path, \"\(key)\"\(c))"
        case "UInt16": return "_assayUInt16(&sink, path, \"\(key)\"\(c))"
        case "UInt32": return "_assayUInt32(&sink, path, \"\(key)\"\(c))"
        case "UInt64": return "_assayUInt64(&sink, path, \"\(key)\"\(c))"
        case "UInt": return "_assayUInt(&sink, path, \"\(key)\"\(c))"
        case "Double": return "_assayDouble(&sink, path, \"\(key)\"\(c))"
        case "Float": return "_assayFloat(&sink, path, \"\(key)\"\(c))"
        case "Bool": return "_assayBool(&sink, path, \"\(key)\"\(c))"
        default: return nil
        }
    }
}

// MARK: - `@Key(path:)` on the RawValue path

extension SchemaMacro {

    /// The path walk for YAML and XML.
    ///
    /// A SECOND PASS over the members, deliberately, and the reason it is not the single-pass
    /// discipline the JSON body holds to is that there is nothing to be single-pass *about*:
    /// the tree is already built and in memory. `PERFORMANCE.md`'s one-pass rule is about not
    /// re-reading BYTES. `first(where:)` over an already-materialised member array is a walk
    /// of a few pointers, and writing a fused version would mean threading path state through
    /// the length-bucketed switch to save nothing measurable.
    ///
    /// The three failure shapes are the JSON body's three, and they have to be: a schema that
    /// reported a missing intermediate differently depending on the wire format would make
    /// `@Key(path:)` a different feature per format.
    static func rawPathDescent(
        _ groups: [PathGroup], fields: [SchemaField], ctx: String
    ) -> String {
        guard !groups.isEmpty else { return "" }
        var out = ""
        for g in groups {
            out += rawNode(
                g.node, fields: fields, source: "__members",
                segment: g.segment, pathExpr: "path", depth: 0, indent: 4, ctx: ctx)
        }
        return out
    }

    private static func rawNode(
        _ n: PathNode, fields: [SchemaField], source: String,
        segment: String, pathExpr: String, depth: Int, indent: Int, ctx: String
    ) -> String {
        let pad = String(repeating: " ", count: indent)
        let v = "__pv\(n.bit)"
        let mm = "__pm\(n.bit)"
        let here = "\(pathExpr) + [.key(\"\(segment)\")]"

        var body = ""
        for (seg, i) in n.leaves {
            let f = fields[i]
            let span = rawNeedsSpan(f) ? "\(pad)            __sp\(i) = __m.span\n" : ""
            body += """
                \(pad)        if __m.key == "\(seg)" {
                \(pad)            __presence |= \(presenceBit(i))
                \(span)\(pad)            \(rawDecodeStatement(field: f, index: i, ctx: ctx))
                \(pad)        }

                """
        }
        // Nested groups resolve from this object's members, after the loop, so a child and a
        // leaf under the same parent cannot see different views of it.
        var deeper = ""
        for (seg, child) in n.children {
            deeper += rawNode(
                child, fields: fields, source: mm,
                segment: seg, pathExpr: here, depth: depth + 1,
                indent: indent + 4, ctx: ctx)
        }

        return """
            \(pad)if let \(v) = \(source).first(where: { $0.key == "\(segment)" })?.value {
            \(pad)    if case .mapping(let \(mm)) = \(v) {
            \(pad)        __gpresence |= \(presenceBit(n.bit))
            \(pad)        for __m in \(mm) {
            \(pad)            let __v = __m.value
            \(pad)            _ = __v
            \(body)\(pad)        }
            \(deeper)\(pad)    } else if \(v).isNull {
            \(pad)        // An explicit null intermediate is absence, as on the JSON path.
            \(pad)    } else {
            \(pad)        Assay.RawValue._mismatchPublic(&sink, \(pathExpr), "\(segment)", "object", \(v))
            \(pad)    }
            \(pad)}

            """
    }

    /// The missing-required rules, nested exactly as `PathTree.presenceChecks` nests them —
    /// same shape, different reporting primitive, because the two decode paths report through
    /// different functions and always have.
    static func rawPathPresence(
        _ groups: [PathGroup], fields: [SchemaField], indent: Int
    ) -> String {
        var out = ""
        for g in groups {
            out += rawChecks(
                g.node, fields: fields, segment: g.segment,
                parentPath: "path", indent: indent)
        }
        return out
    }

    private static func rawChecks(
        _ n: PathNode, fields: [SchemaField], segment: String,
        parentPath: String, indent: Int
    ) -> String {
        let pad = String(repeating: " ", count: indent)
        let here = "\(parentPath) + [.key(\"\(segment)\")]"

        var inner = ""
        for (seg, i) in n.leaves where PathTree.isRequired(fields[i]) {
            inner +=
                "\(pad)    if __presence & \(presenceBit(i)) == 0 {\n"
                + "\(pad)        Assay.RawValue._missing(&sink, \(here), \"\(seg)\")\n"
                + "\(pad)    }\n"
        }
        for (seg, child) in n.children {
            inner += rawChecks(
                child, fields: fields, segment: seg,
                parentPath: here, indent: indent + 4)
        }
        guard !inner.isEmpty else { return "" }

        if PathTree.requiresAnything(n, fields) {
            return "\(pad)if __gpresence & \(presenceBit(n.bit)) == 0 {\n"
                + "\(pad)    Assay.RawValue._missing(&sink, \(parentPath), \"\(segment)\")\n"
                + "\(pad)} else {\n" + inner + "\(pad)}\n"
        }
        return "\(pad)if __gpresence & \(presenceBit(n.bit)) != 0 {\n" + inner + "\(pad)}\n"
    }

}
