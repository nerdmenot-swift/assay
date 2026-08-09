// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The KeyedSource decode body, and the field manifest. docs/KEYED-SOURCE.md.
//
// Opt-in via `@Schema(sources: true)` for the reason every other body is: generated size
// dominates expansion cost, and 85 ms of a 100 ms budget is already spent.
//
// FLAT RECORDS ONLY in the first increment. A database row, an env block and a form post
// have no nested arrays; anything tree-shaped is what the `RawValue` path is for. An array
// or dictionary field is a compile error naming the field, rather than a runtime surprise
// or a silent tree materialisation.
//===----------------------------------------------------------------------===//

extension SchemaMacro {

    static func sourceBody(typeName: String, fields: [SchemaField],
                           validation: String, checks: String) -> String {
        var manifest = ""
        for f in fields {
            manifest += """
                    .init(key: "\(f.wireKey)", kind: \(manifestKind(f.decodedType)), \
            isOptional: \(f.isOptional), hasDefault: \(f.defaultExpr != nil)),

            """
        }

        var lines = ""
        for (i, f) in fields.enumerated() {
            lines += "    " + sourceStatement(field: f, index: i) + "\n"
        }

        var unwraps = ""
        var args: [String] = []
        for (i, f) in fields.enumerated() {
            let raw = f.isOptional ? "__f\(i)" : "__v\(i)"
            if !f.isOptional {
                unwraps += "        guard let __v\(i) = __f\(i) else { return nil }\n"
            }
            if f.transform != nil {
                args.append("\(f.identifier): " + (f.isOptional
                    ? "\(raw).map(Self.__assayTransform_\(i))"
                    : "Self.__assayTransform_\(i)(\(raw))"))
            } else {
                args.append("\(f.identifier): \(raw)")
            }
        }

        var locals = ""
        for (i, f) in fields.enumerated() {
            let base = f.decodedType
            if let d = f.defaultExpr {
                locals += "    var __g\(i): \(base)?? = .some(\(d))\n"
            } else {
                locals += "    var __g\(i): \(base)?? = nil\n"
            }
        }

        // The accessors answer in `T??` — outer nil is "nothing usable", inner nil is a
        // real null. Everything downstream (rules, @Fallback, construction) is written
        // against the `T?` the other two paths use, so flatten once here rather than
        // teaching the shared sections a second shape.
        var flat = ""
        for (i, f) in fields.enumerated() {
            flat += "    var __f\(i): \(f.decodedType)? = __g\(i) ?? nil\n"
        }
        // Spans for validated fields, so a source that can place its fields renders the
        // same carets JSON does.
        for (i, f) in fields.enumerated() where f.needsSpan {
            flat += "    let __sp\(i): Assay.SourceSpan? = source.span(\"\(f.wireKey)\", \(i))\n"
        }

        return """
        /// Every field this type declares, in order, resolved at compile time.
        ///
        /// A record stream has ONE key set for its whole life, so a source binds against
        /// this once rather than resolving keys per record. docs/KEYED-SOURCE.md.
        nonisolated public static let _assayManifest = Assay.FieldManifest(fields: [
        \(manifest)])

        nonisolated public static func _assay<__S: Assay.KeyedSource & ~Copyable>(
            from source: borrowing __S,
            into sink: inout Assay.IssueSink,
            at path: [Assay.PathComponent]
        ) -> \(typeName)? {
        \(locals)
        \(lines)
        \(flat)
        \(validation)
        \(unwraps)    let __result = \(typeName)(\(args.joined(separator: ", ")))
        \(checks)
            guard sink.isValid else { return nil }
            return __result
        }
        """
    }

    static func manifestKind(_ type: String) -> String {
        switch type {
        case "String": return ".string"
        case "Int":    return ".int"
        case "Int64":  return ".int64"
        case "Int32":  return ".int32"
        case "UInt":   return ".uint"
        case "Double": return ".double"
        case "Float":  return ".float"
        case "Bool":   return ".bool"
        default:       return ".nested(\"\(type)\")"
        }
    }

    /// One line per field, everything conditional in the runtime accessor.
    static func sourceStatement(field f: SchemaField, index i: Int) -> String {
        let key = f.wireKey
        let base = f.decodedType
        let opts = "optional: \(f.isOptional), hasDefault: \(f.defaultExpr != nil)"
        let call: String
        switch base {
        case "String":
            call = "Assay._assaySourceString(source, \"\(key)\", \(i), &sink, path, \(opts))"
        case "Bool":
            call = "Assay._assaySourceBool(source, \"\(key)\", \(i), &sink, path, \(opts))"
        case "Double":
            call = "Assay._assaySourceDouble(source, \"\(key)\", \(i), &sink, path, \(opts))"
        case "Float":
            return "if let __r\(i) = Assay._assaySourceDouble(source, \"\(key)\", \(i), &sink, path, \(opts)) { __g\(i) = .some(__r\(i).map(Float.init)) }"
        case "Int64":
            call = "Assay._assaySourceInt64(source, \"\(key)\", \(i), &sink, path, \(opts))"
        case "Int", "Int32", "UInt":
            return "if let __r\(i) = Assay._assaySourceInt64(source, \"\(key)\", \(i), &sink, path, \(opts)) { __g\(i) = .some(__r\(i).flatMap { \(base)(exactly: $0) }) }"
        default:
            // Nested types are out of the first increment: a row addresses one flat
            // namespace, and prefix-addressing is a design question of its own.
            return "// unsupported field kind for a keyed source: \(base)"
        }
        return "if let __r\(i) = \(call) { __g\(i) = .some(__r\(i)) }"
    }

    /// A keyed source is a FLAT record. Anything tree-shaped belongs on the RawValue path,
    /// and saying so at expansion beats a runtime surprise.
    static func sourceDiagnostics(_ fields: [SchemaField]) -> [String] {
        var out: [String] = []
        for f in fields {
            let base = f.decodedType
            if arrayElement(base) != nil || dictionaryValue(base) != nil {
                out.append("'\(f.identifier)' is declared \(f.typeName); a keyed source is "
                    + "a FLAT record (a database row, a form post, an environment block) "
                    + "and has no nested collections. Decode tree-shaped data through the "
                    + "RawValue path instead, or drop `sources: true`")
            } else if manifestKind(base).hasPrefix(".nested") {
                out.append("'\(f.identifier)' is declared \(f.typeName); nested @Schema "
                    + "values are not addressable from a flat keyed source in this "
                    + "release. See docs/KEYED-SOURCE.md")
            }
        }
        return out
    }
}

// MARK: - Columnar batch fill

extension SchemaMacro {

    /// `_assayBatch` — one sequential pass per column, then N constructions.
    ///
    /// The inversion is the whole point. Row-by-row over a column store touches every
    /// column array once per record, so N records over M columns is N×M jumps between M
    /// separate allocations. Pulling each column once is M sequential passes.
    ///
    /// Everything else must stay identical: `@Validate`, `@Fallback` and the five presence
    /// states run per row exactly as they do everywhere else, and issues carry the row
    /// index so a failure in a million-row batch is findable.
    static func batchBody(typeName: String, fields: [SchemaField],
                          validation: String) -> String {
        var pulls = ""
        for (i, f) in fields.enumerated() {
            guard let accessor = columnAccessor(f.decodedType) else { continue }
            let expected = manifestKind(f.decodedType).dropFirst()
            // A column the schema requires and the source lacks is reported ONCE for the
            // batch. Optional and defaulted fields simply carry no column.
            let onMissing = (f.isOptional || f.defaultExpr != nil)
                ? ""
                : """

                        if __c\(i) == nil {
                            Assay._assayColumnMissing(&sink, path, "\(f.wireKey)", "\(expected)")
                        }
                """
            pulls += """
                    let __c\(i) = source.\(accessor)("\(f.wireKey)", \(i))
                    let __n\(i) = source.nulls("\(f.wireKey)", \(i))\(onMissing)

            """
        }

        var perRow = ""
        for (i, f) in fields.enumerated() {
            let base = f.decodedType
            guard columnAccessor(base) != nil else { continue }
            let convert = columnConvert(base, "__col\(i)[__r]")
            let fallbackToDefault = f.defaultExpr.map { "\($0)" }
            let absent = f.isOptional ? "nil" : (fallbackToDefault ?? "nil")
            perRow += """
                        var __f\(i): \(base)? = \(absent)
                        if let __col\(i) = __c\(i), __r < __col\(i).count,
                           !Assay._assayIsNullAt(__n\(i), __r) {
                            __f\(i) = \(convert)
                        }

            """
        }

        var unwraps = ""
        var args: [String] = []
        for (i, f) in fields.enumerated() {
            guard columnAccessor(f.decodedType) != nil else { continue }
            if f.isOptional {
                args.append("\(f.identifier): __f\(i)")
            } else {
                unwraps += """
                            guard let __v\(i) = __f\(i) else {
                                Assay._assaySourceMissing(&sink, path, "\(f.wireKey)", nil)
                                continue
                            }

                """
                args.append("\(f.identifier): __v\(i)")
            }
        }

        return """
        /// Decode a whole batch, one sequential pass per column.
        ///
        /// The inversion a column store wants: N records over M columns row-by-row is N×M
        /// strided reads; this is M sequential ones. Rules, defaults and presence behave
        /// exactly as they do on every other path, and issues carry the row index.
        nonisolated public static func _assayBatch<__C: Assay.ColumnarSource & ~Copyable>(
            from source: borrowing __C,
            into sink: inout Assay.IssueSink,
            at path: [Assay.PathComponent]
        ) -> [\(typeName)] {
        \(pulls)    var __out: [\(typeName)] = []
            __out.reserveCapacity(source.rowCount)

            for __r in 0..<source.rowCount {
                let path = path + [.index(__r)]
        \(perRow)\(validation)
        \(unwraps)        __out.append(\(typeName)(\(args.joined(separator: ", "))))
            }
            return __out
        }
        """
    }

    static func columnAccessor(_ type: String) -> String? {
        switch type {
        case "String": return "stringColumn"
        case "Bool": return "boolColumn"
        case "Double", "Float": return "doubleColumn"
        case "Int", "Int64", "Int32", "UInt": return "int64Column"
        default: return nil
        }
    }

    static func columnConvert(_ type: String, _ expr: String) -> String {
        switch type {
        case "String", "Bool", "Double", "Int64": return expr
        case "Float": return "Float(\(expr))"
        default: return "\(type)(exactly: \(expr))"
        }
    }
}
