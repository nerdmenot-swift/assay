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
        emitKnownKeys: Bool = false
    ) -> String {

        var prefix = ""
        if emitKnownKeys, policy == "warn" || policy == "reject" {
            let names = fields.flatMap { [$0.wireKey] + $0.aliases }
                .map { "\"\($0)\"" }.joined(separator: ", ")
            prefix = """
            nonisolated static let __assayKnownKeys: [String] = [\(names)]


            """
        }

        var locals = ""
        var requiredMask: UInt64 = 0
        for (i, f) in fields.enumerated() {
            let base = stripOptional(f.typeName)
            locals += "    var __f\(i): \(base)? = \(f.defaultExpr ?? "nil")\n"
            if !f.isOptional && f.defaultExpr == nil {
                requiredMask |= (1 << UInt64(i))
            }
        }
        if let e = extras {
            locals += "    var __extras: \(stripOptional(e.typeName)) = [:]\n"
        }

        // Bucket by key length, then compare within the bucket.
        var byLength: [Int: [(Int, SchemaField, String)]] = [:]
        for (i, f) in fields.enumerated() {
            for key in [f.wireKey] + f.aliases {
                byLength[key.utf8.count, default: []].append((i, f, key))
            }
        }

        var arms = ""
        for len in byLength.keys.sorted() {
            var checks = ""
            var first = true
            for (i, f, key) in byLength[len]! {
                checks += "\(first ? "" : " else ")if __k == \"\(key)\" {\n"
                checks += "                    __presence |= \(1 << UInt64(i))\n"
                checks += "                    \(rawDecodeStatement(field: f, index: i))\n"
                checks += "                }"
                first = false
            }
            checks += " else {\n                    \(rawUnknownArm(policy: policy, extras: extras))\n                }"
            arms += """
                        case \(len):
                            \(checks)

            """
        }

        var missing = ""
        for (i, f) in fields.enumerated() where (requiredMask & (1 << UInt64(i))) != 0 {
            missing += """
                    if __presence & \(1 << UInt64(i)) == 0 {
                        Assay.RawValue.missing(&sink, path, "\(f.wireKey)")
                    }

            """
        }

        var indexOf: [String: Int] = [:]
        for (i, f) in fields.enumerated() { indexOf[f.identifier] = i }
        var args: [String] = []
        for f in (ordered ?? fields) {
            if f.isExtras {
                args.append("\(f.identifier): __extras")
            } else if let i = indexOf[f.identifier] {
                args.append("\(f.identifier): \(f.isOptional ? "__f\(i)" : "__v\(i)")")
            }
        }
        var unwraps = ""
        for (i, f) in fields.enumerated() where !f.isOptional {
            unwraps += "        guard let __v\(i) = __f\(i) else { return nil }\n"
        }

        return prefix + """
        nonisolated public static func _assay(
            from raw: Assay.RawValue,
            into sink: inout Assay.IssueSink,
            at path: [Assay.PathComponent]
        ) -> \(typeName)? {
            guard case .mapping(let __members) = raw else {
                Assay.RawValue.notAnObject(&sink, path, raw)
                return nil
            }

        \(locals)    var __presence: UInt64 = 0

            for __m in __members {
                let __k = __m.key
                let __v = __m.value
                switch __k.utf8.count {
        \(arms)            default:
                    \(rawUnknownArm(policy: policy, extras: extras))
                }
            }

        \(missing)
            guard sink.isValid else { return nil }
        \(unwraps)    return \(typeName)(\(args.joined(separator: ", ")))
        }
        """
    }

    static func rawUnknownArm(policy: String, extras: SchemaField?) -> String {
        switch policy {
        case "collect":
            guard let e = extras else { return "break" }
            let value = elementType(stripOptional(e.typeName))
            // RawValue is the only thing a RawValue-shaped decode can produce, so a
            // format-specific extras type is simply not reachable on this path.
            return value.hasSuffix("RawValue")
                ? "__extras[__k] = __v"
                : "break"
        case "warn":
            return "Assay.RawValue.unknownKey(&sink, path, __k, known: Self.__assayKnownKeys, reject: false)"
        case "reject":
            return "Assay.RawValue.unknownKey(&sink, path, __k, known: Self.__assayKnownKeys, reject: true)"
        default:
            return "break"
        }
    }

    /// One line per field, mirroring the JSON body's discipline.
    static func rawDecodeStatement(field f: SchemaField, index i: Int) -> String {
        let base = stripOptional(f.typeName)
        let key = f.wireKey
        let c = f.coerce ? ", coerce: true" : ""

        if let element = arrayElement(base) {
            if let call = rawScalarCall(element, key: key, coerce: f.coerce) {
                return """
                if case .sequence(let __xs) = __v {
                            __f\(i) = __xs.compactMap { $0.\(call) }
                        } else if __v.isNull, \(f.isOptional) {
                            __f\(i) = nil
                        } else {
                            Assay.RawValue.mismatchPublic(&sink, path, "\(key)", "array", __v)
                        }
                """
            }
            return """
            if case .sequence(let __xs) = __v {
                            __f\(i) = __xs.compactMap {
                                \(element)._assay(from: $0, into: &sink,
                                                  at: path + [.key("\(key)")])
                            }
                        } else {
                            Assay.RawValue.mismatchPublic(&sink, path, "\(key)", "array", __v)
                        }
            """
        }

        if let call = rawScalarCall(base, key: key, coerce: f.coerce) {
            if f.isOptional {
                return "if !__v.isNull { __f\(i) = __v.\(call) }"
            }
            return "__f\(i) = __v.\(call)"
        }

        // Nested @Schema type.
        return """
        if __v.isNull {
                            \(f.isOptional
                                ? "__f\(i) = nil"
                                : "Assay.RawValue.mismatchPublic(&sink, path, \"\(key)\", \"\(base)\", __v)")
                        } else {
                            __f\(i) = \(base)._assay(from: __v, into: &sink,
                                                     at: path + [.key("\(key)")])
                        }
        """
        + (c.isEmpty ? "" : "")
    }

    static func rawScalarCall(_ type: String, key: String, coerce: Bool) -> String? {
        let c = coerce ? ", coerce: true" : ""
        switch type {
        case "String":  return "assayString(&sink, path, \"\(key)\"\(c))"
        case "Int":     return "assayInt(&sink, path, \"\(key)\"\(c))"
        case "Int64":   return "assayInt64(&sink, path, \"\(key)\"\(c))"
        case "Int32":   return "assayInt32(&sink, path, \"\(key)\"\(c))"
        case "UInt":    return "assayUInt(&sink, path, \"\(key)\"\(c))"
        case "Double":  return "assayDouble(&sink, path, \"\(key)\"\(c))"
        case "Float":   return "assayFloat(&sink, path, \"\(key)\"\(c))"
        case "Bool":    return "assayBool(&sink, path, \"\(key)\"\(c))"
        default:        return nil
        }
    }
}
