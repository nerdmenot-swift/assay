// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

//===----------------------------------------------------------------------===//
// Open enums — `@Unknown`. docs/EXPERIENCE.md §8, docs/ENCODING.md question 2.
//
// THE SPELLING IN THE ROADMAP DOES NOT COMPILE, and that is worth recording rather than
// quietly fixing. It proposed:
//
//     enum Status: String { case active, suspended; @Unknown case other(String) }
//
// A Swift enum with a raw type cannot have a case with an associated value — the two
// features are mutually exclusive in the language. So the construct changes rather than
// being transliterated, which is CLAUDE.md's governing principle applied to a case it was
// written for: the raw type goes away and `@Schema` supplies the mapping.
//
//     @Schema enum Status {
//         case active, suspended
//         @Unknown case other(String)
//     }
//
// A CLOSED enum still needs no macro at all — `enum P: String, JSONAssayable {}` has been
// the whole implementation since day one and stays the primary path. `@Schema` on an enum
// without an `@Unknown` case is therefore an error that points back at it, rather than a
// second way to do the same thing more slowly.
//
// Never `switch` over a `String` (CLAUDE.md hard constraint 1): matching buckets by UTF-8
// length first and compares within the bucket, exactly as the RawValue decode body does.
//===----------------------------------------------------------------------===//

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

struct EnumCaseInfo {
    var identifier: String
    var wireName: String
    var isUnknown: Bool
    var roundTrips: Bool
}

extension SchemaMacro {

    static func enumExpansion(
        of node: AttributeSyntax,
        enumDecl: EnumDeclSyntax,
        typeName: String,
        in context: some MacroExpansionContext
    ) -> [ExtensionDeclSyntax] {

        let keyStyle = Self.keyStyle(from: node)
        let formats = Self.formats(from: node)
        let wantsEncoding = Self.encodes(from: node)

        var cases: [EnumCaseInfo] = []
        var bad = false

        for member in enumDecl.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            let attrs = caseDecl.attributes.compactMap { $0.as(AttributeSyntax.self) }
            let unknownAttr = attrs.first { $0.attributeName.trimmedDescription == "Unknown" }
            var roundTrips = false
            if let a = unknownAttr, let args = a.arguments?.as(LabeledExprListSyntax.self) {
                for arg in args where arg.label?.text == "roundTrips" {
                    roundTrips = arg.expression.trimmedDescription == "true"
                }
            }
            var wireOverride: String?
            for a in attrs where a.attributeName.trimmedDescription == "Key" {
                if let args = a.arguments?.as(LabeledExprListSyntax.self),
                   let lit = args.first?.expression.as(StringLiteralExprSyntax.self) {
                    wireOverride = lit.segments.description
                }
            }

            for element in caseDecl.elements {
                let name = element.name.text
                let hasPayload = element.parameterClause != nil
                if unknownAttr != nil {
                    // The catch-all must carry exactly one String, or it has nowhere to
                    // put the value it exists to preserve.
                    let params = element.parameterClause?.parameters
                    let ok = params?.count == 1
                        && params?.first?.type.trimmedDescription == "String"
                    if !ok {
                        context.diagnose(Diagnostic(node: Syntax(element),
                            message: SimpleDiagnostic(
                                "@Unknown case '\(name)' must carry exactly one String — "
                                + "that is where the unrecognised value is kept")))
                        bad = true
                    }
                    cases.append(EnumCaseInfo(identifier: name, wireName: name,
                                              isUnknown: true, roundTrips: roundTrips))
                } else {
                    if hasPayload {
                        context.diagnose(Diagnostic(node: Syntax(element),
                            message: SimpleDiagnostic(
                                "case '\(name)' has an associated value; only the "
                                + "@Unknown case may carry one")))
                        bad = true
                    }
                    cases.append(EnumCaseInfo(
                        identifier: name,
                        wireName: wireOverride ?? keyStyle.apply(name),
                        isUnknown: false, roundTrips: false))
                }
            }
        }

        let unknowns = cases.filter(\.isUnknown)
        if unknowns.count > 1 {
            context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                "only one @Unknown case is allowed; found \(unknowns.count)")))
            bad = true
        }
        if unknowns.isEmpty {
            context.diagnose(Diagnostic(node: Syntax(node), message: SimpleDiagnostic(
                "@Schema on an enum is for FORWARD COMPATIBILITY and needs an @Unknown "
                + "case. A closed enum needs no macro at all — write "
                + "`enum \(typeName): String, Assay.JSONAssayable { … }`, which already "
                + "decodes, reports the case list on a bad value, and generates nothing")))
            bad = true
        }
        guard !bad, let unknown = unknowns.first else { return [] }

        let known = cases.filter { !$0.isUnknown }
        var body = ""

        // The wire names, for the error message on a value that is neither known nor
        // capturable, and for did-you-mean.
        body += """
        nonisolated static let __assayCaseNames: [String] = [\(known.map { "\"\($0.wireName)\"" }.joined(separator: ", "))]


        """

        // Length-bucketed matching. Never a String switch (CLAUDE.md constraint 1).
        var byLength: [Int: [EnumCaseInfo]] = [:]
        for c in known { byLength[c.wireName.utf8.count, default: []].append(c) }
        var arms = ""
        for len in byLength.keys.sorted() {
            var checks = ""
            var first = true
            for c in byLength[len]! {
                checks += "\(first ? "" : " else ")if __s == \"\(c.wireName)\" { return .\(c.identifier) }"
                first = false
            }
            arms += "        case \(len): \(checks)\n"
        }

        body += """
        /// The wire string to a case, with the catch-all keeping anything unrecognised —
        /// which is the entire point: a v1 client must survive a v2 server.
        nonisolated public static func _assayFromWire(_ __s: String) -> \(typeName) {
            switch __s.utf8.count {
        \(arms)    default: break
            }
            return .\(unknown.identifier)(__s)
        }

        /// The case back to its wire string. `nil` for an unrecognised value that did not
        /// opt into round-tripping — see `_assayEncodeWire`.
        nonisolated public var _assayWire: String {
            switch self {
        \(known.map { "        case .\($0.identifier): return \"\($0.wireName)\"" }.joined(separator: "\n"))
            case .\(unknown.identifier)(let __v): return __v
            }
        }

        nonisolated public var _assayIsUnknown: Bool {
            if case .\(unknown.identifier) = self { return true }
            return false
        }


        """

        if formats.json {
            body += """
            nonisolated public static func _assay(
                from reader: inout Assay.AssayReader,
                into sink: inout Assay.IssueSink,
                at path: [Assay.PathComponent]
            ) -> \(typeName)? {
                reader.beginValue()
                guard let __s = reader.scanString() else {
                    reader.reportTypeMismatch(&sink, path, expected: "string")
                    return nil
                }
                return _assayFromWire(__s)
            }


            """
        }
        if formats.raw {
            body += """
            nonisolated public static func _assay(
                from raw: Assay.RawValue,
                into sink: inout Assay.IssueSink,
                at path: [Assay.PathComponent]
            ) -> \(typeName)? {
                guard case .string(let __s) = raw else {
                    Assay.RawValue.mismatchAt(&sink, path, "string", raw)
                    return nil
                }
                return _assayFromWire(__s)
            }


            """
        }

        if wantsEncoding {
            // docs/ENCODING.md question 2, the answer that closes it.
            func guardLines(_ ret: String) -> String {
                guard !unknown.roundTrips else { return "" }
                return "    if _assayIsUnknown {\n"
                    + "        Assay._assayUnknownNotEncodable(\"\(typeName)\", "
                    + "_assayWire, &sink, path)\n"
                    + "        return\(ret)\n"
                    + "    }\n"
            }
            let guardExpr = guardLines("")
            let guardExprValue = guardLines(" .null")
            if formats.json {
                body += """
                nonisolated public func _assayEncode(
                    into w: inout Assay.JSONWriter,
                    into sink: inout Assay.IssueSink,
                    at path: [Assay.PathComponent]
                ) {
                \(guardExpr)    w.write(_assayWire)
                }


                """
            }
            if formats.raw {
                body += """
                nonisolated public func _assayEncodeRaw(
                    into sink: inout Assay.IssueSink,
                    at path: [Assay.PathComponent]
                ) -> Assay.RawValue {
                \(guardExprValue)    return .string(_assayWire)
                }


                """
            }
            if formats.xml {
                body += """
                nonisolated public static var _assayXMLRoot: String { "\(typeName)" }

                nonisolated public func _assayEncodeXML(
                    into w: inout Assay.XMLWriter,
                    into sink: inout Assay.IssueSink,
                    at path: [Assay.PathComponent],
                    element __name: String
                ) {
                \(guardExpr)    w.element(__name, _assayWire)
                }


                """
            }
        }

        var conformances: [String] = []
        if formats.json { conformances.append("Assay.JSONAssayable") }
        if formats.raw { conformances.append("Assay.RawDecodable") }
        if wantsEncoding && formats.json { conformances.append("Assay.JSONEncodableSchema") }
        if wantsEncoding && formats.raw { conformances.append("Assay.RawEncodableSchema") }
        if wantsEncoding && formats.xml { conformances.append("Assay.XMLEncodableSchema") }

        let ext = try? ExtensionDeclSyntax(
            "extension \(raw: typeName): \(raw: conformances.joined(separator: ", "))") {
            DeclSyntax(stringLiteral: body)
        }
        return ext.map { [$0] } ?? []
    }
}
