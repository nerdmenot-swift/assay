// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Encoding to `RawValue` — the seam every non-JSON format writes through.
//
// This mirrors the DECODE architecture exactly, which is the reason to do it this way
// rather than emit a YAML writer per type: YAML and XML decode by parsing to their own
// node model, projecting to `RawValue`, and decoding from that. Encoding runs the same
// pipeline backwards — the schema builds a `RawValue`, and each format renders it.
//
// Two things fall out of that symmetry and both are worth having:
//
//   * The macro never learns about YAML. `AssayYAML` renders `RawValue`; the expansion
//     emits no YAML-specific code, so a type that encodes to JSON only does not carry a
//     byte of YAML support, and adding a format later needs no macro change at all.
//   * `RawValue` is already the documented lossy intersection of the three formats
//     (docs/VALUE-MODELS.md §5). Encoding through it makes the losses the SAME losses
//     decoding already has, rather than a second, different set nobody wrote down.
//===----------------------------------------------------------------------===//

extension SchemaMacro {

    /// `_assayEncodeRaw` — the schema as a `RawValue.mapping`, in declaration order.
    static func rawEncodeBody(
        typeName: String,
        fields: [SchemaField],
        extras: SchemaField?
    ) -> String {
        var lines = ""
        for (i, f) in fields.enumerated() {
            let value = f.transform != nil
                ? "Self.__assayInverse_\(i)(self.\(f.identifier))"
                : "self.\(f.identifier)"
            let expr: String
            if f.isOptional {
                // Optional absent encodes as an explicit null, matching the JSON writer:
                // `nil` decoded from an absent key or a null, and null round-trips both.
                expr = "(\(value).map { __o in \(rawExpr(f.decodedType, "__o", key: f.wireKey, index: i)) } ?? .null)"
            } else {
                expr = rawExpr(f.decodedType, value, key: f.wireKey, index: i)
            }
            lines += "        __m.append(.init(key: \"\(f.wireKey)\", value: \(expr)))\n"
        }

        if let e = extras {
            // Q6, same contract as the JSON writer: collected keys are written back, and a
            // collision with a declared key is reported rather than silently duplicated.
            lines += """
                    for __x in self.\(e.identifier).sorted(by: { $0.key < $1.key }) {
                        if Self.__assayDeclaredKeys.contains(__x.key) {
                            sink.add(Assay.Issue(
                                code: .extrasKeyCollision,
                                path: path + [.key(__x.key)],
                                params: ["key": .string(__x.key)]))
                            continue
                        }
                        __m.append(.init(key: __x.key, value: __x.value))
                    }

            """
        }

        return """
        nonisolated public func _assayEncodeRaw(
            into sink: inout Assay.IssueSink,
            at path: [Assay.PathComponent]
        ) -> Assay.RawValue {
            var __m: [Assay.RawValue.Member] = []
            __m.reserveCapacity(\(fields.count))
        \(lines)    return .mapping(__m)
        }
        """
    }

    /// A `RawValue` expression for one value of `type`.
    static func rawExpr(_ type: String, _ expr: String, key: String, index i: Int) -> String {
        if isDateType(type) {
            return "Assay._assayRawDate(\(expr).timeIntervalSince1970, Self.__assayDateFormats_\(i))"
        }
        if let element = arrayElement(type) {
            return ".sequence(\(expr).map { __e\(i) in \(rawExpr(element, "__e\(i)", key: key, index: i)) })"
        }
        if let value = dictionaryValue(type) {
            // Sorted, for the same reason the JSON writer sorts: a Dictionary has no order
            // and an unstable encoding makes the round-trip law untestable.
            return ".mapping(\(expr).keys.sorted().map { __k\(i) in "
                + ".init(key: __k\(i), value: \(rawExpr(value, "\(expr)[__k\(i)]!", key: key, index: i))) })"
        }
        switch type {
        case "String":              return ".string(\(expr))"
        case "Bool":                return ".bool(\(expr))"
        case "Int", "Int32", "UInt",
             "Int8", "Int16", "UInt8", "UInt16", "UInt32", "UInt64":
            return ".int(Int64(\(expr)))"
        case "Int64":               return ".int(\(expr))"
        case "Double":              return ".double(\(expr))"
        case "Float":               return ".double(Double(\(expr)))"
        case "RawValue", "Assay.RawValue": return "\(expr)"
        default:
            return "\(expr)._assayEncodeRaw(into: &sink, at: path + [.key(\"\(key)\")])"
        }
    }
}
