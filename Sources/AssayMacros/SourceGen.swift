// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// The field manifest and the columnar batch body. docs/KEYED-SOURCE.md.
//
// Opt-in via `@Schema(sources: true)`, for the reason every other body is: generated
// size dominates expansion cost, and a type that never reads a column store must not pay
// for one.
//===----------------------------------------------------------------------===//

extension SchemaMacro {

    /// Every field this type declares, in order, resolved at compile time. A columnar
    /// source binds against this once per batch rather than per record.
    static func manifestBody(typeName: String, fields: [SchemaField]) -> String {
        var manifest = ""
        for f in fields {
            manifest += """
                    .init(key: "\(f.wireKey)", kind: \(manifestKind(f.decodedType)), \
            isOptional: \(f.isOptional), hasDefault: \(f.defaultExpr != nil)),

            """
        }
        return """
        nonisolated public static let _assayManifest = Assay.FieldManifest(fields: [
        \(manifest)])
        """
    }

    /// A blob column. Spelled out rather than derived, because `arrayElement` says "an
    /// array of UInt8" and the whole point is that this one is a scalar.
    static func isBytes(_ type: String) -> Bool {
        type == "[UInt8]" || type == "Array<UInt8>"
    }

    static func manifestKind(_ type: String) -> String {
        switch type {
        case "Int8":   return ".int8"
        case "Int16":  return ".int16"
        case "UInt8":  return ".uint8"
        case "UInt16": return ".uint16"
        case "UInt32": return ".uint32"
        case "UInt64": return ".uint64"
        case "String": return ".string"
        case "Int":    return ".int"
        case "Int64":  return ".int64"
        case "Int32":  return ".int32"
        case "UInt":   return ".uint"
        case "Double": return ".double"
        case "Float":  return ".float"
        case "Bool":   return ".bool"
        default:       return isBytes(type) ? ".bytes" : ".custom(\"\(type)\")"
        }
    }

    /// A columnar source is a FLAT batch of scalar columns. Anything tree-shaped belongs
    /// on the RawValue path, and saying so at expansion beats a runtime surprise.
    ///
    /// What is NOT refused here is a field whose type the macro does not recognise. It used
    /// to be, and that was the wrong shape of answer: expansion is syntactic, so `Date`,
    /// `UUID`, a consumer's `Timestamp` and a genuine nested `@Schema` all arrive as the
    /// same identifier token, and refusing the lot of them meant refusing four types that
    /// have a perfectly good columnar representation in order to catch the one that does
    /// not. Such a field now takes the `ColumnDecodable` path; the compiler checks the
    /// conformance, which is the only thing in the pipeline that CAN check it.
    static func sourceDiagnostics(_ fields: [SchemaField]) -> [String] {
        var out: [String] = []
        for f in fields {
            let base = f.decodedType
            // `[UInt8]` is a blob, not a nested collection — it goes to `bytesColumn`
            // through the `ColumnDecodable` conformance on `Array where Element == UInt8`.
            guard !isBytes(base) else { continue }
            if arrayElement(base) != nil || dictionaryValue(base) != nil {
                out.append("'\(f.identifier)' is declared \(f.typeName); a columnar source "
                    + "is a batch of flat scalar columns and has no nested collections. "
                    + "Decode tree-shaped data through the RawValue path instead, or drop "
                    + "`sources: true`")
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
                          validation: String, checks: String = "") -> String {
        var pulls = ""
        for (i, f) in fields.enumerated() {
            guard isColumnar(f.decodedType) else { continue }
            // What the missing-column issue names as the expected shape. NOT the manifest
            // kind's spelling: `.custom("Instant")` carries quotes, and this is interpolated
            // into a generated string literal. The declared type is the better answer here
            // in any case -- "expected: Instant" beats "expected: custom".
            let expected = columnAccessor(f.decodedType) != nil
                ? String(manifestKind(f.decodedType).dropFirst())
                : (isBytes(f.decodedType) ? "bytes" : f.decodedType)
            // A column the schema requires and the source lacks is reported ONCE for the
            // batch. Optional and defaulted fields simply carry no column.
            let onMissing = (f.isOptional || f.defaultExpr != nil)
                ? ""
                : """

                        if __c\(i) == nil {
                            Assay._assayColumnMissing(&sink, path, "\(f.wireKey)", "\(expected)")
                            __columnMissing = true
                        }
                """
            // Both fetches are ONE call per column for the whole batch, which is what makes
            // the generic one on the second line affordable: it is the shape that cost
            // KeyedSource 1.6-4.7x when it was paid per row, and dividing it by the row
            // count is the entire reason this design works. See ColumnDecodable.swift.
            // `@Key(_:or:)`: the aliases are tried in order when the primary column is
            // absent, and the one that matched is reported once for the batch — the same
            // warning the tree paths record per document.
            let fetch: (String) -> String = columnAccessor(f.decodedType) != nil
                ? { "source.\(columnAccessor(f.decodedType)!)(\"\($0)\", \(i))" }
                : { "Assay._assayFetchColumn(\(f.decodedType).self, from: source, \"\($0)\", \(i))" }
            var aliasArms = ""
            for alias in f.aliases {
                aliasArms += """

                        if __c\(i) == nil, let __a = \(fetch(alias)) {
                            __c\(i) = __a
                            __k\(i) = "\(alias)"
                            Assay._assayAliasMatched(&sink, path, "\(f.wireKey)", "\(alias)")
                        }
                """
            }
            let binding = f.aliases.isEmpty ? "let" : "var"
            let keyVar = f.aliases.isEmpty ? "" : "\n        var __k\(i): StaticString = \"\(f.wireKey)\""
            let nullsKey = f.aliases.isEmpty ? "\"\(f.wireKey)\"" : "__k\(i)"
            // TEXT CELLS. A CSV, an Excel sheet, a text-format wire value: the column is
            // strings whatever the field declares. Under `coerceScalars` / `@Coerce` a
            // numeric or boolean field takes the string column when its own kind is
            // absent, parsed per row by the same rules the tree path uses; a `Date` field
            // always does, because text is what a date IS on every other path. The
            // missing-column check then covers both shapes.
            let textFallback = textFallsBack(f)
            let textPull = textFallback
                ? "\n        let __t\(i): [String]? = __c\(i) == nil ? source.stringColumn(\(nullsKey), \(i)) : nil"
                : ""
            let missing = textFallback && !onMissing.isEmpty
                ? """

                        if __c\(i) == nil, __t\(i) == nil {
                            Assay._assayColumnMissing(&sink, path, "\(f.wireKey)", "\(expected)")
                            __columnMissing = true
                        }
                """
                : onMissing
            if columnAccessor(f.decodedType) != nil || textFallback {
                pulls += """
                        \(binding) __c\(i) = \(fetch(f.wireKey))\(keyVar)\(aliasArms)\(textPull)
                        let __n\(i) = source.nulls(\(nullsKey), \(i))\(missing)

                """
            } else {
                pulls += """
                        \(binding) __c\(i) = \(fetch(f.wireKey))\(keyVar)\(aliasArms)\(missing)

                """
            }
        }

        var perRow = ""
        for (i, f) in fields.enumerated() {
            let base = f.decodedType
            guard isColumnar(base) else { continue }
            let fallbackToDefault = f.defaultExpr.map { "\($0)" }
            let absent = f.isOptional ? "nil" : (fallbackToDefault ?? "nil")
            // The per-row call in the second branch names `base` concretely, in the module
            // that declares the schema, so it is a direct call and not a witness one.
            let (mask, convert) = columnAccessor(base) != nil
                ? ("__n\(i)", columnConvert(base, "__col\(i)[__r]"))
                : ("__col\(i).nulls",
                   "\(base)(assayColumn: __col\(i), row: __r, metadata: __col\(i).metadata)")
            let typed: String
            if narrowsInt64(base) {
                // A value the declared width cannot hold is an overflow, not an absence.
                typed = """
                            var __f\(i): \(base)? = \(absent)
                            if let __col\(i) = __c\(i), __r < __col\(i).count,
                               !Assay._assayIsNullAt(\(mask), __r) {
                                guard let __x\(i) = \(convert) else {
                                    Assay._assayRowOverflow(&sink, path, "\(f.wireKey)", __col\(i)[__r])
                                    continue
                                }
                                __f\(i) = __x\(i)
                            }
                """
            } else {
                typed = """
                            var __f\(i): \(base)? = \(absent)
                            if let __col\(i) = __c\(i), __r < __col\(i).count,
                               !Assay._assayIsNullAt(\(mask), __r) {
                                __f\(i) = \(convert)
                            }
                """
            }
            perRow += typed + textBranch(f, i) + "\n\n"
        }

        var unwraps = ""
        var args: [String] = []
        for (i, f) in fields.enumerated() {
            guard isColumnar(f.decodedType) else { continue }
            if f.isOptional {
                args.append("\(f.name): __f\(i)")
            } else {
                unwraps += """
                            guard let __v\(i) = __f\(i) else {
                                Assay._assayRowMissing(&sink, path, "\(f.wireKey)")
                                continue
                            }

                """
                args.append("\(f.name): __v\(i)")
            }
        }

        // A required column the source lacks means no row can be built. Say so once and
        // stop, rather than running the loop to report `missing` per row under the
        // `missing_column` already filed — which is what happened until 2026-09-10: a
        // thousand rows produced one column issue, a hundred row issues (the cap) and
        // `truncatedIssues`, for a batch whose problem was one sentence long.
        let hasRequired = fields.contains { isColumnar($0.decodedType) && !$0.isOptional && $0.defaultExpr == nil }
        let missingGuard = hasRequired ? """
                if __columnMissing { return [] }

        """ : ""
        let missingFlag = hasRequired ? "    var __columnMissing = false\n" : ""
        // A row that reported anything is not a value, on this path as on every other:
        // `values` holds the rows that decoded clean, `issues` names the rest by index.
        // Until 2026-09-10 a rule violation was reported AND the row was appended. Only
        // emitted when there are rules — the presence checks above `continue` themselves.
        let rowGuard = validation.isEmpty && checks.isEmpty ? ("", "") : (
            "        let __rck = sink.checkpoint()\n",
            "        if sink.checkpoint() != __rck { continue }\n")
        // `@Check`s run on the constructed value, as on every other path — they did not
        // run on this one until 2026-09-10. Only emitted when there are checks; a
        // check-free type constructs straight into the output array.
        let construct = checks.isEmpty
            ? "        __out.append(\(typeName)(\(args.joined(separator: ", "))))\n"
            : """
                    let __result = \(typeName)(\(args.joined(separator: ", ")))
            \(checks)        if sink.checkpoint() != __rck { continue }
                    __out.append(__result)

            """

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
        \(missingFlag)\(pulls)\(missingGuard)    var __out: [\(typeName)] = []
            __out.reserveCapacity(source.rowCount)

            // The row index reaches every issue through the sink, not through a path built
            // per row: `sink.add` inserts it, cold, only when something is reported.
            for __r in 0..<source.rowCount {
                sink._enterRow(__r, depth: path.count)
        \(perRow)\(rowGuard.0)\(validation)\(rowGuard.1)
        \(unwraps)\(construct)    }
            sink._leaveRows()
            return __out
        }
        """
    }

    /// Whether a field gets columnar code at all.
    ///
    /// True for the built-in scalars, for `[UInt8]`, and — this is the change — for any
    /// spelling the macro does not recognise, which now goes through `ColumnDecodable`.
    /// False only for what expansion can actually prove is tree-shaped, which `sourceDiagnostics`
    /// has already refused by the time this matters.
    static func isColumnar(_ type: String) -> Bool {
        if columnAccessor(type) != nil || isBytes(type) { return true }
        return arrayElement(type) == nil && dictionaryValue(type) == nil
    }

    static func columnAccessor(_ type: String) -> String? {
        switch type {
        case "String": return "stringColumn"
        case "Bool": return "boolColumn"
        case "Double", "Float": return "doubleColumn"
        case "Int", "Int64", "Int32", "UInt",
             "Int8", "Int16", "UInt8", "UInt16", "UInt32", "UInt64":
            return "int64Column"
        default: return nil
        }
    }

    /// Whether a field takes a `String` column when its own kind is absent: a coercing
    /// number or boolean, or a `Date`.
    static func textFallsBack(_ f: SchemaField) -> Bool {
        let t = f.decodedType
        if isDateType(t) { return true }
        guard f.coerce, let accessor = columnAccessor(t) else { return false }
        return accessor != "stringColumn"
    }

    /// The per-row text branch — `else if` after the typed one — parsing the cell by the
    /// rules the tree path uses (`_assayCoerceInt64` and friends, `RawValue._assayDate`),
    /// so a cell that is not a number says `type_mismatch` with the row and the text.
    static func textBranch(_ f: SchemaField, _ i: Int) -> String {
        guard textFallsBack(f) else { return "" }
        let t = f.decodedType
        let key = f.wireKey
        let head = """
             else if let __txt\(i) = __t\(i), __r < __txt\(i).count,
                           !Assay._assayIsNullAt(__n\(i), __r) {

            """
        let body: String
        if isDateType(t) {
            body = """
                            guard let __s\(i) = Assay.RawValue.string(__txt\(i)[__r])._assayDate(&sink, path, "\(key)", \(dateFormatsRef(f, i))) else { continue }
                            __f\(i) = \(t)(timeIntervalSince1970: __s\(i))

            """
        } else if t == "Bool" {
            body = """
                            guard let __x\(i) = Assay._assayCoerceBool(__txt\(i)[__r]) else {
                                Assay._assayRowMismatch(&sink, path, "\(key)", "boolean", __txt\(i)[__r]); continue
                            }
                            __f\(i) = __x\(i)

            """
        } else if t == "Double" || t == "Float" {
            body = """
                            guard let __x\(i) = Assay._assayCoerceDouble(__txt\(i)[__r]) else {
                                Assay._assayRowMismatch(&sink, path, "\(key)", "number", __txt\(i)[__r]); continue
                            }
                            __f\(i) = \(t == "Float" ? "Float(__x\(i))" : "__x\(i)")

            """
        } else {
            // An integer: parse to Int64, then the declared width exactly as a typed
            // column would, so overflow is overflow here too.
            let narrow = narrowsInt64(t)
                ? """
                                guard let __y\(i) = \(t)(exactly: __x\(i)) else {
                                    Assay._assayRowOverflow(&sink, path, "\(key)", __x\(i)); continue
                                }
                                __f\(i) = __y\(i)
                """
                : "                __f\(i) = __x\(i)"
            body = """
                            guard let __x\(i) = Assay._assayCoerceInt64(__txt\(i)[__r]) else {
                                Assay._assayRowMismatch(&sink, path, "\(key)", "integer", __txt\(i)[__r]); continue
                            }
            \(narrow)

            """
        }
        return head + body + "            }"
    }

    /// Declared narrower than the `Int64` column that carries it, so `exactly:` can fail.
    static func narrowsInt64(_ type: String) -> Bool {
        switch type {
        // `Int` too: it is 32 bits on wasm32, and the conversion is `exactly:` there as well.
        case "Int", "Int32", "UInt", "Int8", "Int16", "UInt8", "UInt16", "UInt32", "UInt64": return true
        default: return false
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
