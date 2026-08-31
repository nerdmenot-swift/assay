// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Emitting the XML encode body. docs/ENCODING.md.
//
// Unlike YAML, XML does not go through the `RawValue` seam — placement is not expressible
// there. It IS expressible at compile time, which is where it lives: `@XML(.attribute)`
// becomes an `attribute(_:_:)` call and everything else becomes an element, with the
// attributes emitted FIRST because XML requires them inside the start tag.
//
// The two defaults, both settled by surveying the field rather than by taste:
//   * an unannotated field is an ELEMENT (Jackson, Go, .NET, pydantic-xml all agree, and
//     none defaults to an attribute);
//   * an unannotated array is UNWRAPPED REPEATED SIBLINGS (Go and serde-xml-rs, the two
//     whose XML support was designed rather than retrofitted onto a JSON mapper).
// `@XML(.wrapped)` is the opt-in for the one thing unwrapped cannot express: the
// difference between an absent array and an empty one.
//===----------------------------------------------------------------------===//

extension SchemaMacro {

    static func xmlEncodeBody(
        typeName: String,
        fields: [SchemaField],
        extras: SchemaField?
    ) -> String {
        // Attributes first — XML requires them in the start tag, and the writer closes
        // that tag on the first content call.
        var attrs = ""
        var content = ""

        for (i, f) in fields.enumerated() {
            let value = f.transform != nil
                ? "Self.__assayInverse_\(i)(self.\(f.identifier))"
                : "self.\(f.identifier)"
            switch f.xmlPlacement {
            case "attribute":
                attrs += attributeLine(f, index: i, value: value)
            case "text":
                content += textLine(f, index: i, value: value)
            default:
                content += elementLines(f, index: i, value: value)
            }
        }

        if let e = extras {
            content += """
                    for __x in self.\(e.identifier).sorted(by: { $0.key < $1.key }) {
                        if Self.__assayDeclaredKeys.contains(__x.key) {
                            sink.add(Assay.Issue(
                                code: .extrasKeyCollision,
                                path: path + [.key(__x.key)],
                                params: ["key": .string(__x.key)]))
                            continue
                        }
                        Assay._assayEncodeRawXML(__x.value, named: __x.key, into: &w,
                                                 into: &sink, at: path)
                    }

            """
        }

        return """
        nonisolated public static var _assayXMLRoot: String { "\(typeName)" }

        nonisolated public func _assayEncodeXML(
            into w: inout Assay.XMLWriter,
            into sink: inout Assay.IssueSink,
            at path: [Assay.PathComponent],
            element __name: String
        ) {
            w.beginElement(__name)
        \(attrs)\(content)    w.endElement(__name)
        }
        """
    }

    static func attributeLine(_ f: SchemaField, index i: Int, value: String) -> String {
        let key = f.wireKey
        let expr = scalarText(f.decodedType, f.isOptional ? "__a\(i)" : value,
                              key: key, index: i)
        if f.isOptional {
            // An absent attribute is simply not written — XML has no null, and an empty
            // attribute would decode as the empty string rather than as nil.
            return """
                    if let __a\(i) = \(value) { w.attribute("\(key)", \(expr)) }

            """
        }
        return "        w.attribute(\"\(key)\", \(expr))\n"
    }

    static func textLine(_ f: SchemaField, index i: Int, value: String) -> String {
        let expr = scalarText(f.decodedType, f.isOptional ? "__t\(i)" : value,
                              key: f.wireKey, index: i)
        if f.isOptional {
            return "        if let __t\(i) = \(value) { w.text(\(expr)) }\n"
        }
        return "        w.text(\(expr))\n"
    }

    static func elementLines(_ f: SchemaField, index i: Int, value: String) -> String {
        let key = f.wireKey
        let base = f.decodedType

        if let element = arrayElement(base) {
            let inner = elementWrite(element, "__e\(i)", name: "\"\(key)\"",
                                     key: key, index: i, indent: 12)
            if f.xmlPlacement == "wrapped" {
                // The wrapper is always written, even when empty — which is the entire
                // point of asking for it: `<tags/>` is empty, nothing at all is absent.
                return """
                        w.beginElement("\(key)")
                        for __e\(i) in \(f.isOptional ? "(\(value) ?? [])" : value) {
                \(inner)
                        }
                        w.endElement("\(key)")

                """
            }
            return """
                    for __e\(i) in \(f.isOptional ? "(\(value) ?? [])" : value) {
            \(inner)
                    }

            """
        }

        if f.isOptional {
            // Absent writes nothing at all rather than an empty element, so absent and
            // present-but-empty stay distinguishable on the way back in.
            return """
                    if let __o\(i) = \(value) {
            \(elementWrite(base, "__o\(i)", name: "\"\(key)\"", key: key, index: i, indent: 12))
                    }

            """
        }
        return elementWrite(base, value, name: "\"\(key)\"", key: key, index: i, indent: 8) + "\n"
    }

    /// Write one non-optional value as an element called `name`.
    static func elementWrite(
        _ type: String, _ expr: String, name: String, key: String, index i: Int, indent: Int
    ) -> String {
        let pad = String(repeating: " ", count: indent)
        if isDateType(type) {
            return "\(pad)w.element(\(name), Assay._assayXMLDate(\(expr).timeIntervalSince1970, Self.__assayDateFormats_\(i)))"
        }
        if let value = dictionaryValue(type) {
            return """
            \(pad)w.beginElement(\(name))
            \(pad)for __dk\(i) in \(expr).keys.sorted() {
            \(elementWrite(value, "\(expr)[__dk\(i)]!", name: "__dk\(i)", key: key, index: i, indent: indent + 4))
            \(pad)}
            \(pad)w.endElement(\(name))
            """
        }
        switch type {
        case "String", "Int", "Int64", "Int32", "UInt", "Bool",
             "Int8", "Int16", "UInt8", "UInt16", "UInt32", "UInt64":
            return "\(pad)w.element(\(name), \(expr))"
        case "Double", "Float":
            return "\(pad)w.element(\(name), w.doubleText(Double(\(expr)), &sink, path, \"\(key)\"))"
        case "RawValue", "Assay.RawValue":
            return "\(pad)Assay._assayEncodeRawXML(\(expr), named: \(name), into: &w, into: &sink, at: path)"
        default:
            return "\(pad)\(expr)._assayEncodeXML(into: &w, into: &sink, at: path + [.key(\"\(key)\")], element: \(name))"
        }
    }

    /// A scalar rendered as text, for attribute and `.text` placement.
    static func scalarText(_ type: String, _ expr: String, key: String, index i: Int) -> String {
        if isDateType(type) {
            return "Assay._assayXMLDate(\(expr).timeIntervalSince1970, Self.__assayDateFormats_\(i))"
        }
        switch type {
        case "String":  return expr
        case "Bool":    return "(\(expr) ? \"true\" : \"false\")"
        case "Double", "Float":
            return "w.doubleText(Double(\(expr)), &sink, path, \"\(key)\")"
        default:        return "String(\(expr))"
        }
    }

    /// `@XML(.attribute)` and `.text` only mean anything for scalars, and `.wrapped` only
    /// for arrays. Caught at expansion, like every other placement mistake.
    static func xmlDiagnostics(_ fields: [SchemaField]) -> [String] {
        var out: [String] = []
        for f in fields {
            let base = f.decodedType
            let isArray = arrayElement(base) != nil
            switch f.xmlPlacement {
            case "attribute", "text":
                if isArray || dictionaryValue(base) != nil {
                    out.append("@XML(.\(f.xmlPlacement!)) applies to scalar fields; "
                        + "'\(f.identifier)' is declared \(f.typeName), which cannot be "
                        + "flattened into \(f.xmlPlacement == "attribute" ? "an attribute" : "character data")")
                }
            case "wrapped":
                if !isArray {
                    out.append("@XML(.wrapped) applies to array fields; "
                        + "'\(f.identifier)' is declared \(f.typeName)")
                }
            default: break
            }
        }
        return out
    }
}
