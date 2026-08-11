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

    /// A columnar source is a FLAT batch of scalar columns. Anything tree-shaped belongs
    /// on the RawValue path, and saying so at expansion beats a runtime surprise.
    static func sourceDiagnostics(_ fields: [SchemaField]) -> [String] {
        var out: [String] = []
        for f in fields {
            let base = f.decodedType
            if arrayElement(base) != nil || dictionaryValue(base) != nil {
                out.append("'\(f.identifier)' is declared \(f.typeName); a columnar source "
                    + "is a batch of flat scalar columns and has no nested collections. "
                    + "Decode tree-shaped data through the RawValue path instead, or drop "
                    + "`sources: true`")
            } else if manifestKind(base).hasPrefix(".nested") {
                out.append("'\(f.identifier)' is declared \(f.typeName); nested @Schema "
                    + "values are not addressable from a flat columnar source. "
                    + "See docs/KEYED-SOURCE.md")
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
                                Assay._assayRowMissing(&sink, path, "\(f.wireKey)")
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
